import Foundation
import Combine

struct Tokens: Equatable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    static func + (a: Tokens, b: Tokens) -> Tokens {
        Tokens(input: a.input + b.input,
               output: a.output + b.output,
               cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
               cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
               cacheRead: a.cacheRead + b.cacheRead)
    }

    static func += (a: inout Tokens, b: Tokens) { a = a + b }
}

/// One aggregation bucket: a day, a project, a model.
struct BucketKey: Hashable {
    let day: Date
    let project: String
    let model: String
}

struct ProjectUsage: Identifiable {
    var id: String { project }
    let project: String
    let tokens: Tokens
    let cost: Double
}

struct DayUsage: Identifiable {
    var id: Date { day }
    let day: Date
    let tokens: Tokens
    let cost: Double
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var todayTokens = Tokens()
    @Published private(set) var todayCost: Double = 0
    @Published private(set) var todayByProject: [ProjectUsage] = []
    @Published private(set) var last7Days: [DayUsage] = []
    @Published private(set) var lastRefresh = Date()
    @Published private(set) var scanError: String?

    private var buckets: [BucketKey: Tokens] = [:]
    /// Byte offset of the last complete line consumed, per transcript file.
    private var offsets: [String: UInt64] = [:]
    /// Project directory path -> display name, resolved once from a transcript's
    /// `cwd` and reused so incremental scans keep a stable bucket key.
    private var projectNames: [String: String] = [:]
    private var timer: Timer?
    /// Guards against overlapping scans double-counting — see refresh().
    private var isScanning = false

    private let projectsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects")
    private let calendar = Calendar(identifier: .gregorian)

    func start() {
        // onAppear fires every time the popover is rebuilt; without this guard
        // each open would stack another timer and rescan on every tick.
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Drops the request if a scan is already running.
    ///
    /// Not an optimisation — a correctness guard. scan() is deterministic for a
    /// given offset map, and apply() *adds* what it returns. Two overlapping
    /// scans both start from the same offsets, both read the same new bytes, and
    /// both get added: every token in that window counts twice. Nothing detects
    /// it afterwards; the totals are simply wrong and still look plausible.
    ///
    /// Skipping is safe. The offsets aren't advanced until a scan lands, so
    /// whatever this call would have read is still unread, and the running scan
    /// or the next tick picks it up.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let root = projectsRoot
        let known = offsets
        let knownNames = projectNames
        Task.detached(priority: .utility) {
            let result = Self.scan(root: root, offsets: known, names: knownNames)
            await MainActor.run {
                // Clear before apply so a throwing apply can't wedge the flag on
                // and freeze every future refresh.
                self.isScanning = false
                self.apply(result)
            }
        }
    }

    private func apply(_ result: ScanResult) {
        for (key, tokens) in result.buckets {
            buckets[key, default: Tokens()] += tokens
        }
        offsets = result.offsets
        projectNames = result.names
        scanError = result.error
        lastRefresh = Date()
        recompute()
    }

    private func recompute() {
        let today = calendar.startOfDay(for: Date())

        var todayTotal = Tokens()
        var todayCostSum = 0.0
        var byProject: [String: (Tokens, Double)] = [:]
        var byDay: [Date: (Tokens, Double)] = [:]

        for (key, tokens) in buckets {
            let cost = Pricing.cost(of: tokens, model: key.model, at: key.day)

            var d = byDay[key.day] ?? (Tokens(), 0)
            d.0 += tokens; d.1 += cost
            byDay[key.day] = d

            guard key.day == today else { continue }
            todayTotal += tokens
            todayCostSum += cost
            var p = byProject[key.project] ?? (Tokens(), 0)
            p.0 += tokens; p.1 += cost
            byProject[key.project] = p
        }

        todayTokens = todayTotal
        todayCost = todayCostSum
        todayByProject = byProject
            .map { ProjectUsage(project: $0.key, tokens: $0.value.0, cost: $0.value.1) }
            .sorted { $0.cost > $1.cost }

        last7Days = (0..<7).reversed().compactMap { offset -> DayUsage? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let entry = byDay[day] ?? (Tokens(), 0)
            return DayUsage(day: day, tokens: entry.0, cost: entry.1)
        }
    }

    // MARK: - Scanning (off the main actor)

    struct ScanResult {
        var buckets: [BucketKey: Tokens] = [:]
        var offsets: [String: UInt64] = [:]
        var names: [String: String] = [:]
        var error: String?
    }

    nonisolated private static func scan(root: URL,
                                         offsets: [String: UInt64],
                                         names: [String: String]) -> ScanResult {
        var result = ScanResult()
        result.offsets = offsets
        result.names = names

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            result.error = "~/.claude/projects not found"
            return result
        }

        let calendar = Calendar(identifier: .gregorian)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

            let projectName: String
            if let cached = result.names[dir.path] {
                projectName = cached
            } else {
                projectName = resolveProjectName(dir: dir, fm: fm)
                result.names[dir.path] = projectName
            }

            // Recursive: subagent transcripts live at
            // <project>/<session>/subagents/*.jsonl and are billed too.
            let files = fm.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "jsonl" } ?? []

            for file in files {
                let path = file.path
                let start = offsets[path] ?? 0

                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }

                let size = (try? handle.seekToEnd()) ?? 0
                // Transcripts are append-only; a shrunken file means it was
                // rotated or rewritten, so re-read it from the top.
                let from = size < start ? 0 : start
                if size == from { continue }

                try? handle.seek(toOffset: from)
                guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

                // Stop at the last newline — the tail may be a half-written line.
                guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let complete = data[data.startIndex...lastNewline]
                result.offsets[path] = from + UInt64(complete.count)

                for lineData in complete.split(separator: UInt8(ascii: "\n")) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                          obj["type"] as? String == "assistant",
                          let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any],
                          let model = message["model"] as? String,
                          let stamp = obj["timestamp"] as? String
                    else { continue }

                    guard let date = iso.date(from: stamp) ?? isoPlain.date(from: stamp) else { continue }

                    // Prefer the 5m/1h breakdown; fall back to the flat total
                    // (billed at the 5m rate) when the breakdown is absent.
                    let creation = usage["cache_creation"] as? [String: Any]
                    let write5m: Int
                    let write1h: Int
                    if let creation {
                        write5m = creation["ephemeral_5m_input_tokens"] as? Int ?? 0
                        write1h = creation["ephemeral_1h_input_tokens"] as? Int ?? 0
                    } else {
                        write5m = usage["cache_creation_input_tokens"] as? Int ?? 0
                        write1h = 0
                    }

                    let tokens = Tokens(
                        input: usage["input_tokens"] as? Int ?? 0,
                        output: usage["output_tokens"] as? Int ?? 0,
                        cacheWrite5m: write5m,
                        cacheWrite1h: write1h,
                        cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
                    )

                    let key = BucketKey(day: calendar.startOfDay(for: date),
                                        project: projectName,
                                        model: model)
                    result.buckets[key, default: Tokens()] += tokens
                }
            }
        }
        return result
    }

    /// Fires overlapping refreshes at a real store and checks the totals are
    /// still right. Without the guard in refresh() this double-counts, and the
    /// wrong number looks entirely plausible — which is exactly why it needs a
    /// test rather than a careful reading.
    @MainActor static func raceTestAndExit() -> Never {
        let expected = scan(root: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects"), offsets: [:], names: [:])
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        var want = Tokens()
        for (key, tokens) in expected.buckets where key.day == today { want += tokens }
        print("one clean scan:      \(want.total) tokens")

        let store = UsageStore()
        // Same tick, before any of them can land — the overlap the guard exists
        // for. A click landing on a timer tick is this, just rarer.
        for _ in 0..<5 { store.refresh() }
        RunLoop.main.run(until: Date().addingTimeInterval(4))

        let got = store.todayTokens.total
        print("after 5x refresh():  \(got) tokens")
        if got == want.total {
            print("✅ no double-count")
            exit(0)
        }
        let ratio = want.total > 0 ? Double(got) / Double(want.total) : 0
        print("❌ counted \(String(format: "%.1f", ratio))x — the guard is not holding")
        exit(1)
    }

    /// Runs the real scan + pricing path and prints the result. Used to verify
    /// the numbers the menu bar shows without needing the UI.
    nonisolated static func dumpAndExit() -> Never {
        QuotaStore.dump()
        print()
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let result = scan(root: root, offsets: [:], names: [:])
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())

        var grand = Tokens(), grandCost = 0.0
        var todayTotal = Tokens(), todayCost = 0.0

        for (key, tokens) in result.buckets.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            let cost = Pricing.cost(of: tokens, model: key.model, at: key.day)
            grand += tokens; grandCost += cost
            if key.day == today { todayTotal += tokens; todayCost += cost }
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.calendar = calendar
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let day = dayFormatter.string(from: key.day)
            // padding(toLength:) truncates longer strings — pad manually so a
            // long project name isn't silently clipped in the output.
            let name = key.project.count >= 14
                ? key.project
                : key.project + String(repeating: " ", count: 14 - key.project.count)
            print("\(day)  \(name)"
                + "  \(key.model)  in=\(tokens.input) out=\(tokens.output) "
                + "cw5m=\(tokens.cacheWrite5m) cw1h=\(tokens.cacheWrite1h) cr=\(tokens.cacheRead) "
                + "$\(String(format: "%.4f", cost))")
        }
        print("---")
        print("ALL TIME: \(grand.total) tokens, $\(String(format: "%.4f", grandCost))")
        print("TODAY:    \(todayTotal.total) tokens, $\(String(format: "%.4f", todayCost))")
        if let e = result.error { print("ERROR: \(e)") }
        exit(0)
    }

    /// The directory name is a lossy encoding of the project path — both `/`
    /// and `_` become `-`, so `claude_status` and `claude/status` are
    /// indistinguishable and splitting on `-` mangles the name. The transcripts
    /// record the real `cwd`, so read that instead and only fall back to the
    /// encoded name when no session has one.
    nonisolated private static func resolveProjectName(dir: URL, fm: FileManager) -> String {
        let transcripts = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "jsonl" } ?? []

        for file in transcripts {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            // `cwd` shows up within the first few lines; a small head read is
            // enough and keeps this cheap.
            guard let head = try? handle.read(upToCount: 64_000) else { continue }

            for line in head.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let cwd = obj["cwd"] as? String, !cwd.isEmpty
                else { continue }
                return URL(fileURLWithPath: cwd).lastPathComponent
            }
        }

        // Fallback: strip the leading separator and show the encoded form
        // rather than inventing a name by splitting on an ambiguous delimiter.
        var name = dir.lastPathComponent
        while name.hasPrefix("-") { name.removeFirst() }
        return name.isEmpty ? dir.lastPathComponent : name
    }
}
