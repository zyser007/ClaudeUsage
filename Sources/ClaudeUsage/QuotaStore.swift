import Foundation
import Combine

struct QuotaLimit: Identifiable {
    let id: String
    let label: String
    let percent: Int
    let severity: String
    let resetsAt: Date?

    var isWarning: Bool { severity != "normal" }
}

/// Reads the quota snapshot Claude Code caches in ~/.claude.json
/// (`cachedUsageUtilization`).
///
/// The file is a cache, not a live feed. Measured on this machine: ordinary API
/// traffic does *not* rewrite it — only the `/usage` command triggers a fresh
/// fetch. Running `claude -p "/usage"` does the same from outside, which is how
/// `liveRefresh()` forces the snapshot forward; the plain `refresh()` just
/// re-reads whatever is on disk.
@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var limits: [QuotaLimit] = []
    @Published private(set) var planName: String?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var available = true
    @Published private(set) var isRefreshingLive = false
    @Published private(set) var liveError: String?

    private let configURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude.json")
    private var timer: Timer?
    private var liveTimer: Timer?

    /// A snapshot older than this has stopped tracking reality.
    ///
    /// With the CLI present we re-fetch about every 6 minutes, so 15 minutes
    /// means two-plus failed attempts — something is actually wrong. Without it
    /// we're back to waiting on Claude Code's own schedule (measured 16–45 min
    /// apart), where even an hour-old snapshot is ordinary and warning early
    /// would just cry wolf.
    var isStale: Bool {
        guard let fetchedAt else { return true }
        let limit: TimeInterval = canRefreshLive ? 900 : 7200
        return Date().timeIntervalSince(fetchedAt) > limit
    }

    /// These percentages are a point-in-time measurement, not a live reading —
    /// even with liveRefresh() driving the CLI they can be minutes behind.
    /// Stamping the section with the measurement time makes that visible rather
    /// than something the user has to infer.
    var snapshotLabel: String {
        guard let fetchedAt else { return "Never measured" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "HH:mm"
        return "Measured \(f.string(from: fetchedAt))"
    }

    /// Human-readable age, used in the tooltip and the stale warning. Phrased to
    /// read as a fragment ("5 min ago"), since callers embed it mid-sentence.
    var ageDescription: String {
        guard let fetchedAt else { return "never" }
        let mins = Int(Date().timeIntervalSince(fetchedAt) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins) min ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours) hr ago" }
        return "\(hours / 24) days ago"
    }

    /// Subscription plans aren't billed per token, so the cost figure computed
    /// from transcripts is notional and must be labelled as such.
    var isSubscription: Bool {
        guard let planName = planName?.lowercased() else { return false }
        return ["max", "pro", "team", "enterprise"].contains { planName.contains($0) }
    }

    /// Path to the `claude` CLI, or nil when it isn't installed.
    ///
    /// PATH is not usable here: a menu bar app launched by Finder or
    /// SMAppService inherits a minimal PATH that excludes every usual install
    /// location, so probe the known ones directly.
    nonisolated static let cliPath: String? = {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    var canRefreshLive: Bool { Self.cliPath != nil }

    /// An empty directory to run the CLI in.
    ///
    /// A child process inherits our working directory, and a Finder-launched
    /// app gets `/`. Claude Code treats its working directory as the workspace,
    /// so from the filesystem root it walks into every TCC-protected location in
    /// turn — Photos, Music, iCloud Drive, network volumes, Documents — and each
    /// one raises its own permission prompt, attributed to this app because we
    /// are the responsible parent. Handing it an empty directory it owns leaves
    /// nothing to walk into.
    nonisolated static let cliWorkingDirectory: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage/cli-cwd", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func start() {
        // onAppear fires every time the popover is rebuilt; without this guard
        // each open would stack another timer pair — and every extra live timer
        // spawns its own CLI process.
        guard timer == nil else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        Task { @MainActor in
            // Await the first read before the first liveRefresh: fetchedAt is
            // nil until it lands, and liveRefresh's age check falls through on
            // nil — so firing them in order would spawn the CLI on every launch
            // no matter how fresh the snapshot already was.
            await self.load()
            guard self.canRefreshLive else { return }
            self.liveRefresh()
            // Tick often, spawn rarely: the tick only compares a timestamp, and
            // liveRefresh() decides whether a process is warranted. Polling at
            // the refresh interval instead would beat against the CLI's own
            // throttle and land on half the ticks — see refreshInterval.
            self.liveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.liveRefresh() }
            }
        }
    }

    /// How old the snapshot must be before spawning the CLI is worth it.
    ///
    /// The CLI throttles its own re-fetch and serves cache below that window.
    /// Measured on this machine: a 327s-old snapshot was *not* refetched, a
    /// 359s-old one was — so the cutoff sits just under 6 minutes. Asking any
    /// sooner spawns a process that returns the same numbers.
    private static let refreshInterval: TimeInterval = 360

    /// Forces the snapshot forward by running `claude -p "/usage"`, then
    /// re-reads the file the CLI rewrites.
    ///
    /// Verified on this machine: the CLI reports `Total cost: $0.0000` and
    /// `0 input, 0 output` for this command, and it takes ~1s. We deliberately
    /// don't parse its printed panel — that's display text that can change any
    /// release, while the JSON it writes is structured and already handled by
    /// `read(url:)`.
    ///
    /// - Parameter force: skip the age check, for an explicit user request. The
    ///   CLI's own throttle may still serve cache, so this isn't a guarantee.
    func liveRefresh(force: Bool = false) {
        guard !isRefreshingLive, let path = Self.cliPath else { return }
        if !force, let fetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.refreshInterval { return }
        isRefreshingLive = true
        liveError = nil
        Task.detached(priority: .userInitiated) {
            let error = Self.runUsageCommand(path: path)
            await MainActor.run {
                self.isRefreshingLive = false
                self.liveError = error
                self.refresh()
            }
        }
    }

    nonisolated private static func runUsageCommand(path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // Nothing about /usage depends on a workspace, so give the CLI as little
        // to look at as possible: an empty directory, no session file, and none
        // of the user's customizations. Without this it inherits `/` and scans.
        process.arguments = ["-p", "/usage", "--safe-mode", "--no-session-persistence"]
        process.currentDirectoryURL = cliWorkingDirectory
        // We want the side effect, not the text. Null out stdin too so the CLI
        // can't block waiting on a terminal that isn't there.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            return "Couldn't run claude: \(error.localizedDescription)"
        }

        // Watchdog: measured runs finish in 1–3s. A hung CLI must not leak a
        // process or wedge isRefreshingLive on forever.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            return "claude -p /usage hung for over 20s"
        }
        return process.terminationStatus == 0
            ? nil
            : "claude -p /usage failed (exit \(process.terminationStatus))"
    }

    func refresh() {
        Task { @MainActor in await self.load() }
    }

    /// Awaitable form of `refresh()`, for callers that need `fetchedAt` to be
    /// populated before they act on it.
    private func load() async {
        let url = configURL
        let snapshot = await Task.detached(priority: .utility) { Self.read(url: url) }.value
        limits = snapshot.limits
        planName = snapshot.plan
        fetchedAt = snapshot.fetchedAt
        available = snapshot.available
    }

    private struct Snapshot {
        var limits: [QuotaLimit] = []
        var plan: String?
        var fetchedAt: Date?
        var available = false
    }

    nonisolated private static func read(url: URL) -> Snapshot {
        var snap = Snapshot()

        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return snap }

        if let account = root["oauthAccount"] as? [String: Any],
           let tier = (account["organizationRateLimitTier"] ?? account["userRateLimitTier"]) as? String {
            snap.plan = prettyPlan(tier)
        }

        guard let cached = root["cachedUsageUtilization"] as? [String: Any] else { return snap }
        snap.available = true

        if let ms = cached["fetchedAtMs"] as? Double {
            snap.fetchedAt = Date(timeIntervalSince1970: ms / 1000)
        }

        guard let utilization = cached["utilization"] as? [String: Any],
              let rows = utilization["limits"] as? [[String: Any]]
        else { return snap }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        snap.limits = rows.enumerated().compactMap { index, row in
            guard let kind = row["kind"] as? String else { return nil }
            let percent = row["percent"] as? Int ?? 0
            let stamp = row["resets_at"] as? String
            let resets = stamp.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }

            return QuotaLimit(
                id: "\(kind)-\(index)",
                label: label(kind: kind, scope: row["scope"] as? [String: Any]),
                percent: percent,
                severity: row["severity"] as? String ?? "normal",
                resetsAt: resets
            )
        }
        return snap
    }

    /// Exercises the real CLI-discovery + spawn path and reports whether the
    /// snapshot actually moved. `liveRefresh()` is fire-and-forget from the UI,
    /// so this is the only way to see it fail.
    nonisolated static func liveTest() -> Never {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        print("cliPath: \(cliPath ?? "ไม่พบ claude CLI")")
        guard let path = cliPath else { exit(1) }

        let before = read(url: url).fetchedAt
        print("before: \(before.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "—")")

        let started = Date()
        let error = runUsageCommand(path: path)
        print("ใช้เวลา: \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        print("error: \(error ?? "none")")

        let after = read(url: url).fetchedAt
        print("after:  \(after.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "—")")
        if let b = before, let a = after {
            let moved = a.timeIntervalSince(b)
            print(moved > 0
                  ? "✅ snapshot ขยับ +\(Int(moved))s"
                  : "⚠️ snapshot ไม่ขยับ (CLI throttle: cache ยังใหม่อยู่)")
        }
        exit(0)
    }

    /// Runs the real read + label path and prints it, so the rendered rows can
    /// be checked against what `/usage` shows without the UI.
    nonisolated static func dump() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        let snap = read(url: url)
        print("Plan: \(snap.plan ?? "—")")
        print("available: \(snap.available)")
        if let f = snap.fetchedAt {
            print("fetchedAt: \(f)  (อายุ \(Int(Date().timeIntervalSince(f))) วินาที)")
        }
        print("--- limits ---")
        for l in snap.limits {
            let resets = l.resetsAt.map { "resets in \(Format.until($0))" } ?? "no reset"
            print("  \(l.label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(l.percent)%  [\(l.severity)]  \(resets)")
        }
    }

    nonisolated private static func label(kind: String, scope: [String: Any]?) -> String {
        let modelName = (scope?["model"] as? [String: Any])?["display_name"] as? String

        switch kind {
        case "session":
            return "Session (5hr)"
        case "weekly_all":
            return "Weekly (7 day)"
        case "weekly_scoped":
            return modelName.map { "Weekly \($0)" } ?? "Weekly (scoped)"
        default:
            let pretty = kind.replacingOccurrences(of: "_", with: " ").capitalized
            return modelName.map { "\(pretty) \($0)" } ?? pretty
        }
    }

    /// "default_claude_max_5x" -> "Claude Max 5×"
    nonisolated private static func prettyPlan(_ tier: String) -> String {
        var s = tier
        for prefix in ["default_", "raven_"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        return s.split(separator: "_")
            .map { part -> String in
                if part.hasSuffix("x"), Int(part.dropLast()) != nil {
                    return part.dropLast() + "×"
                }
                return part.capitalized
            }
            .joined(separator: " ")
    }
}
