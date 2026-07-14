import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var quota: QuotaStore
    @ObservedObject var launch: LaunchAtLogin

    /// Which 7-day bar the pointer is over, for the floating cost label.
    @State private var hoveredDay: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            planHeader
            quotaSection
            Divider()
            header

            if let error = store.scanError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            breakdown
            Divider()
            projects
            Divider()
            sparkline
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            store.start()
            quota.start()
            launch.refresh()
        }
    }

    // MARK: - Quota (from Claude Code's cache)

    private var planHeader: some View {
        HStack {
            Text("Plan").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(quota.planName ?? "—").font(.caption.weight(.medium))
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Text("USAGE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if quota.available {
                    if quota.isRefreshingLive {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else if quota.isStale {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                    Text(quota.snapshotLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(quota.isStale ? .orange : .secondary)
                        .help(snapshotHelp)
                }
            }

            if !quota.available {
                Text("No quota data in ~/.claude.json yet — open Claude Code once first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(quota.limits) { limit in
                    quotaRow(limit)
                }
                if let err = quota.liveError {
                    Text(err)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// The wording turns on whether the CLI is actually installed — claiming an
    /// auto-refresh that can't happen would be worse than saying nothing.
    private var snapshotHelp: String {
        quota.canRefreshLive
            ? """
              Measured \(quota.ageDescription) · refreshed automatically every \
              ~6 min by running claude -p "/usage", which costs no quota. \
              Press Refresh to update now.
              """
            : """
              These percentages are what Claude Code measured \
              \(quota.ageDescription). No claude CLI found here, so the app \
              can't refresh them itself — it has to wait for Claude Code to \
              write new values (usually 15–45 min).
              """
    }

    private func quotaRow(_ limit: QuotaLimit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(limit.label).font(.caption)
                Spacer()
                // Icon carries the alert too — colour alone excludes anyone who
                // can't distinguish the orange/red bar from the blue one.
                if let symbol = severitySymbol(limit) {
                    Image(systemName: symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(barColor(limit))
                }
                Text("\(limit.percent)%")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    // 0% must render as an empty track — a minimum-width nub
                    // would read as "some usage".
                    if limit.percent > 0 {
                        Capsule()
                            .fill(barColor(limit))
                            .frame(width: max(3, geo.size.width * Double(limit.percent) / 100))
                    }
                }
            }
            .frame(height: 5)
            if let resets = limit.resetsAt {
                Text("Resets in \(Format.until(resets))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func barColor(_ limit: QuotaLimit) -> Color {
        if limit.isWarning || limit.percent >= 90 { return .red }
        if limit.percent >= 75 { return .orange }
        return .accentColor
    }

    private func severitySymbol(_ limit: QuotaLimit) -> String? {
        if limit.isWarning || limit.percent >= 90 { return "exclamationmark.circle.fill" }
        if limit.percent >= 75 { return "exclamationmark.triangle.fill" }
        return nil
    }

    // MARK: - Token spend (computed from local transcripts)

    /// Cost leads, not total tokens: the total is ~95% cache reads, which are
    /// the cheapest token type and a sign caching is working — showing it in
    /// 22pt made ordinary sessions look alarming.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today (from transcripts)")
                .font(.caption).foregroundStyle(.secondary)
            // Cost only — the output-token count lives in the breakdown below,
            // so repeating it here (rounded differently) just read as noise.
            // The ≈ stays as a quiet marker that this is notional API-equivalent
            // cost, not a subscription charge (tooltip spells it out).
            Text(quota.isSubscription
                 ? "≈\(Format.money(store.todayCost))"
                 : Format.money(store.todayCost))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .help(quota.isSubscription
                      ? "What these tokens would cost at API rates — your subscription is not charged this"
                      : "")
        }
    }

    private var breakdown: some View {
        let t = store.todayTokens
        // Ordered by what the money actually goes to. A category that's zero for
        // this account (e.g. 5m cache writes) would otherwise be a permanent
        // empty row — drop it and only show what's real.
        let rows: [(String, Int)] = [
            ("Output", t.output),
            ("Input", t.input),
            ("Cache write 5m", t.cacheWrite5m),
            ("Cache write 1h", t.cacheWrite1h),
            ("Cache read", t.cacheRead),
        ].filter { $0.1 > 0 }

        return VStack(spacing: 4) {
            ForEach(rows, id: \.0) { row($0.0, $0.1) }
            if !rows.isEmpty {
                Divider().padding(.vertical, 1)
                row("Total", t.total, emphasised: true)
            }
        }
    }

    private func row(_ label: String, _ value: Int, emphasised: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(emphasised ? .primary : .secondary)
            Spacer()
            Text(Format.fullTokens(value))
                .font(emphasised ? .caption.weight(.medium) : .caption)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var projects: some View {
        if store.todayByProject.isEmpty {
            Text("No usage today yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 5) {
                ForEach(store.todayByProject) { p in
                    HStack(spacing: 8) {
                        Text(p.project).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        // Share of today's cost — the honest "where did the
                        // money go" signal. Token share would over-weight
                        // cache-read-heavy projects.
                        Text(costShare(p))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Text(Format.tokens(p.tokens.total))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        Text(Format.money(p.cost))
                            .font(.caption).monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Project's share of today's total cost, rounded. Guards the empty-day
    /// divide-by-zero and avoids showing "0%" for a project that did cost
    /// something.
    private func costShare(_ p: ProjectUsage) -> String {
        guard store.todayCost > 0 else { return "—" }
        let pct = p.cost / store.todayCost * 100
        if pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    private var sparkline: some View {
        let peak = store.last7Days.map(\.cost).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Last 7 days (cost per day)")
                .font(.caption).foregroundStyle(.secondary)
            // Top padding reserves room for the floating label so it doesn't
            // collide with the header above.
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(store.last7Days) { d in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            // Faint baseline so a $0 day reads as "nothing",
                            // not as a short bar equal to a tiny-spend day.
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(height: 34)
                            if d.cost > 0, peak > 0 {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(isToday(d.day) ? Color.accentColor
                                                         : Color.secondary.opacity(0.5))
                                    .frame(height: max(3, 34 * d.cost / peak))
                            }
                        }
                        .frame(maxWidth: 20)
                        // Floating cost label — appears instantly on hover,
                        // above the bar. Faster and better-placed than .help().
                        .overlay(alignment: .top) {
                            if hoveredDay == d.day {
                                Text(d.cost > 0 ? Format.money(d.cost) : "No usage")
                                    .font(.system(size: 9, weight: .semibold))
                                    .monospacedDigit()
                                    .fixedSize()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(d.cost > 0 ? Color.accentColor
                                                                  : Color.secondary))
                                    .foregroundStyle(.white)
                                    .offset(y: -17)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                    .zIndex(1)
                            }
                        }
                        Text(dayLabel(d.day))
                            .font(.system(size: 9))
                            .foregroundStyle(isToday(d.day) ? .primary : .secondary)
                    }
                    // Whole column is hoverable, including the empty space above
                    // a short bar.
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = d.day }
                        else if hoveredDay == d.day { hoveredDay = nil }
                    }
                    .help(d.cost > 0
                          ? "\(Format.money(d.cost)) · \(Format.fullTokens(d.tokens.total)) tokens"
                          : "No usage")
                }
            }
            .padding(.top, 16)
            .animation(.easeOut(duration: 0.12), value: hoveredDay)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at Login", isOn: $launch.isEnabled)
                .toggleStyle(.checkbox)
                .font(.caption)
            if let err = launch.errorMessage {
                Text(err).font(.system(size: 9)).foregroundStyle(.orange)
            }
            HStack {
                // Named explicitly: this is the transcript scan, a different
                // clock from the quota snapshot stamped in the USAGE header.
                Text("Scanned \(store.lastRefresh, format: .dateTime.hour().minute().second())")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") {
                    store.refresh()
                    quota.refresh()
                    // Also drives the CLI so the quota percentages move, not
                    // just the transcript scan. Forced: an explicit click should
                    // try even if our own age check would have skipped. No-op
                    // when the CLI is absent.
                    quota.liveRefresh(force: true)
                }
                .buttonStyle(.link).font(.caption)
                .disabled(quota.isRefreshingLive)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func isToday(_ d: Date) -> Bool {
        Calendar(identifier: .gregorian).isDateInToday(d)
    }

    private func dayLabel(_ d: Date) -> String {
        // Today is named, not abbreviated: it's the highlighted bar and the one
        // a glance has to land on without counting backwards from Saturday.
        if isToday(d) { return "Today" }
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: d)
        return symbols[(weekday - 1) % 7]
    }
}
