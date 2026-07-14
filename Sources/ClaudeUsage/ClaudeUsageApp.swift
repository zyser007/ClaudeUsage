import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var store = UsageStore()
    @StateObject private var quota = QuotaStore()
    @StateObject private var launch = LaunchAtLogin()

    init() {
        if CommandLine.arguments.contains("--dump") {
            UsageStore.dumpAndExit()
        }
        if CommandLine.arguments.contains("--login-status") {
            LaunchAtLogin.printStatus()
        }
        if CommandLine.arguments.contains("--login-test") {
            LaunchAtLogin.selfTest()
        }
        if CommandLine.arguments.contains("--live-test") {
            QuotaStore.liveTest()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store, quota: quota, launch: launch)
        } label: {
            if let icon = MenuIcon.image {
                // Nearest-neighbour keeps pixel art crisp instead of smearing
                // it when scaled to menu bar height.
                Image(nsImage: icon).interpolation(.none)
            } else {
                // Fallback: SF Symbol, not a unicode glyph — U+2301 renders as
                // a stray arrow in the menu bar font.
                Image(systemName: gaugeSymbol)
            }
            Text(labelText)
                .monospacedDigit()
                // The label is what's on screen all day, so the timers have to
                // run whether or not the popover was ever opened. Starting them
                // from MenuContentView.onAppear left the percentage frozen at
                // its launch value until the first click. start() is idempotent.
                .onAppear {
                    store.start()
                    quota.start()
                    launch.refresh()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private var sessionPercent: Int? {
        quota.limits.first { $0.label.hasPrefix("Session") }?.percent
    }

    /// The needle tracks session quota, so the icon alone carries a signal.
    private var gaugeSymbol: String {
        switch sessionPercent {
        case .none: return "gauge.with.dots.needle.bottom.50percent"
        case .some(let p) where p >= 75: return "gauge.with.dots.needle.bottom.100percent"
        case .some(let p) where p >= 34: return "gauge.with.dots.needle.bottom.50percent"
        default: return "gauge.with.dots.needle.bottom.0percent"
        }
    }

    /// Session quota only — cost stays inside the dropdown.
    ///
    /// The percent is a snapshot. QuotaStore drives the CLI to refresh it every
    /// few minutes, so a small lag is normal and fine to show bare; the marker
    /// is for when that has stopped working and the number no longer tracks
    /// reality.
    private var labelText: String {
        guard let sessionPercent else { return "—" }
        return quota.isStale ? "\(sessionPercent)%⚠" : "\(sessionPercent)%"
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fk", Double(n) / 1_000)
        default:
            return "\(n)"
        }
    }

    static func money(_ d: Double) -> String {
        d >= 100 ? String(format: "$%.0f", d) : String(format: "$%.2f", d)
    }

    static func fullTokens(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "4h", "38m", "3d" — matches how the /usage panel phrases resets.
    static func until(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
