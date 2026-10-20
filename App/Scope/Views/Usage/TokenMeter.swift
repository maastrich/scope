import SwiftUI
import ScopeAdapters
import ScopeControl
import ScopeCore
import ScopeTasks

/// The usage meter, a band at the bottom of the sidebar. With a subscription it leads with what matters to one: the
/// share consumed of the window nearest its ceiling and the time to its reset (`84% · 3 d 4 h`), a bar under it
/// coloured by how close it is, as Claude Code reports it to its status line. Clicking it opens the detail of every
/// window — the 5-hour session, the week, a per-model week when the plan has one — and, under them, the tokens: what
/// the threads consumed, who spent most. Without limits (an API key, or no thread answered yet) the band is the token
/// count it used to be, and the detail says the limits are unknown.
struct UsageMeterBand: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false
    @State private var hovered = false

    var body: some View {
        let usage = model.tokenUsage
        if model.config.preferences.showTokenMeter, usage.hasUsage {
            let now = usage.clock
            VStack(spacing: 0) {
                Divider()
                Button {
                    shown.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        if let limits = usage.currentLimits(now: now), let tightest = limits.tightest(now: now) {
                            HStack(spacing: 6) {
                                LimitRing(percentage: tightest.usedPercentage)
                                    .frame(width: 10, height: 10)
                                Text(tightest.label)
                                    .font(.scopeCaption)
                                    .foregroundStyle(Ink.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(RateLimitText.headline(tightest, now: now))
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(limits.isStale(now: now) ? Ink.secondary : Ink.primary)
                                    .lineLimit(1)
                            }
                            LimitBar(percentage: tightest.usedPercentage, height: 3)
                        } else {
                            let windows = usage.snapshot.all
                            let budget = model.config.preferences.tokenBudgetPer5h
                            HStack(spacing: 6) {
                                Image(systemName: "circle.dotted.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Ink.secondary)
                                Text("Tokens · 5h")
                                    .font(.scopeCaption)
                                    .foregroundStyle(Ink.secondary)
                                Spacer(minLength: 4)
                                Text(TokenUsageText.compact(windows.fiveHours.counts.total)
                                     + (budget > 0 ? " / " + TokenUsageText.compact(budget) : ""))
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Ink.primary)
                            }
                            if budget > 0 {
                                TokenGauge(used: windows.fiveHours.counts.total, budget: budget)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(hovered ? Fill.hover : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .usageID("sidebar.usage-meter", label: "Usage meter (sidebar)")
                .help(help(now: now))
                .accessibilityLabel(accessibility(now: now))
                .popover(isPresented: $shown, arrowEdge: .trailing) {
                    TokenUsagePopover()
                }
            }
            .background(Surface.surface)
        }
    }

    private func help(now: Date) -> String {
        let usage = model.tokenUsage
        if let limits = usage.currentLimits(now: now) {
            let parts = limits.current(now: now).map { "\($0.label): \(RateLimitText.percent($0.usedPercentage)) used, \(RateLimitText.reset($0, now: now))" }
            return (usage.planLabel.map { $0 + " — " } ?? "") + parts.joined(separator: " · ")
                + ". Reported by Claude Code \(RateLimitText.age(limits.reportedAt, now: now))."
        }
        return "Tokens Claude Code threads consumed in the last 5 hours — \(TokenUsageText.compact(usage.snapshot.all.sevenDays.counts.total)) over 7 days. Plan limits: \(RateLimitText.unknown)."
    }

    private func accessibility(now: Date) -> String {
        let usage = model.tokenUsage
        if let limits = usage.currentLimits(now: now), let tightest = limits.tightest(now: now) {
            return "\(tightest.label): \(RateLimitText.percent(tightest.usedPercentage)) used, \(RateLimitText.reset(tightest, now: now))"
        }
        return "Tokens: \(TokenUsageText.compact(usage.snapshot.all.fiveHours.counts.total)) in the last 5 hours"
    }
}

/// The colour of a share of a limit: quiet under half, the checks' amber from half on, their red near the ceiling.
enum RateLimitStyle {
    static func color(_ level: RateLimitLevel) -> Color {
        switch level {
        case .calm: Ink.secondary
        case .watch: PullRequestStyle.pending
        case .tight, .exhausted: PullRequestStyle.failing
        }
    }
}

/// A small ring filled to `percentage`, the band's glyph for a limit.
struct LimitRing: View {
    let percentage: Double

    var body: some View {
        let fraction = min(1, max(0, percentage / 100))
        ZStack {
            Circle().stroke(Fill.pressed, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(RateLimitStyle.color(RateLimitLevel(percentage: percentage)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

/// A thin bar of `percentage` of a limit, coloured by level.
struct LimitBar: View {
    let percentage: Double
    var height: CGFloat = 4

    var body: some View {
        let fraction = min(1, max(0, percentage / 100))
        GeometryReader { proxy in
            Capsule()
                .fill(RateLimitStyle.color(RateLimitLevel(percentage: percentage)))
                .frame(width: proxy.size.width * fraction)
        }
        .frame(height: height)
        .background(Fill.pressed, in: Capsule())
        .accessibilityHidden(true)
    }
}

/// A 4 pt bar of `used` against the user's own `budget`; past it, the bar turns to the warning colour.
struct TokenGauge: View {
    let used: Int
    let budget: Int

    var body: some View {
        let fraction = budget > 0 ? Double(used) / Double(budget) : 0
        GeometryReader { proxy in
            Capsule()
                .fill(fraction >= 1 ? ThreadStateStyle.waiting : Ink.secondary)
                .frame(width: proxy.size.width * min(1, max(0, fraction)))
        }
        .frame(height: 4)
        .background(Fill.pressed, in: Capsule())
        .accessibilityElement()
        .accessibilityLabel("Budget")
        .accessibilityValue("\(TokenUsageText.compact(used)) of \(TokenUsageText.compact(budget))")
    }
}

/// The meter's breakdown: the plan's windows first, then the tokens — the three rolling windows, what the five hours
/// are made of, each scope and the top threads.
struct TokenUsagePopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let usage = model.tokenUsage
        let now = usage.clock
        let snapshot = usage.snapshot
        let preferences = model.config.preferences
        let limits = usage.currentLimits(now: now)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(limits == nil ? "Usage" : "Plan limits")
                    .font(.scopeTitle)
                Spacer()
                Text(usage.planLabel ?? (usage.isPerTokenBilling ? "API billing" : "Claude Code threads"))
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            }

            if let limits {
                VStack(spacing: 8) {
                    ForEach(limits.current(now: now)) { window in
                        limitRow(window, now: now)
                    }
                }
                Text(limitsFootnote(limits, now: now))
                    .font(.scopeCaption)
                    .foregroundStyle(limits.isStale(now: now) ? PullRequestStyle.pending : Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            } else if !usage.isPerTokenBilling {
                Text("Plan limits: " + RateLimitText.unknown + ".")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            if !snapshot.threads.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Tokens")
                    Spacer()
                    if preferences.showAPICost {
                        Text("API-equivalent")
                            .font(.scopeMicro)
                            .foregroundStyle(Ink.tertiary)
                            .textCase(.uppercase)
                    }
                }
                VStack(spacing: 4) {
                    windowRow("Last 5 hours", snapshot.all.fiveHours, budget: preferences.tokenBudgetPer5h, cost: preferences.showAPICost)
                    windowRow("Today", snapshot.all.today, cost: preferences.showAPICost)
                    windowRow("Last 7 days", snapshot.all.sevenDays, cost: preferences.showAPICost)
                }

                breakdown(snapshot.all.fiveHours.counts)

                let scopes = snapshot.scopes.values.filter { !$0.windows.sevenDays.counts.isZero }
                    .sorted { ($0.windows.fiveHours.counts.total, $0.windows.sevenDays.counts.total) > ($1.windows.fiveHours.counts.total, $1.windows.sevenDays.counts.total) }
                if scopes.count > 1 {
                    section("By scope") {
                        ForEach(scopes) { row in
                            pairRow(model.tokenScopeName(row.id), detail: nil, row.windows)
                        }
                    }
                }

                let top = snapshot.topThreads(6)
                if !top.isEmpty {
                    section("Top threads") {
                        ForEach(top) { row in
                            pairRow(model.tokenThreadTitle(row), detail: threadDetail(row), row.windows)
                        }
                    }
                }

                Divider()
                Text(footnote(cost: preferences.showAPICost, limits: limits != nil))
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    private func limitRow(_ window: RateLimits.Window, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label)
                    .font(.scopeRow)
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 4)
                Text(RateLimitText.reset(window, now: now))
                    .font(.scopeCaption.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
                Text(RateLimitText.percent(window.usedPercentage))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(window.level == .calm ? Ink.primary : RateLimitStyle.color(window.level))
                    .frame(minWidth: 40, alignment: .trailing)
            }
            LimitBar(percentage: window.usedPercentage)
            if let used = window.usedUSD, let limit = window.limitUSD {
                Text("$\(used.formatted(.number.precision(.fractionLength(2)))) of $\(limit.formatted(.number.precision(.fractionLength(0))))"
                     + (window.period.map { " · \($0)" } ?? ""))
                    .font(.scopeCaption.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label): \(RateLimitText.percent(window.usedPercentage)) used, \(RateLimitText.reset(window, now: now))")
    }

    private func limitsFootnote(_ limits: RateLimits, now: Date) -> String {
        var text = "As Claude Code reported them \(RateLimitText.age(limits.reportedAt, now: now)), for the whole account."
        if limits.isStale(now: now) {
            text += " Usage from claude.ai or another machine since then is not in."
        }
        return text
    }

    private func windowRow(_ label: String, _ window: TokenWindow, budget: Int = 0, cost: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.scopeRow)
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: 4)
                if cost {
                    Text(dollars(window))
                        .font(.scopeCaption.monospacedDigit())
                        .foregroundStyle(Ink.tertiary)
                }
                Text(TokenUsageText.compact(window.counts.total) + (budget > 0 ? " / " + TokenUsageText.compact(budget) : ""))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            if budget > 0 {
                TokenGauge(used: window.counts.total, budget: budget)
            }
        }
    }

    private func breakdown(_ counts: TokenCounts) -> some View {
        HStack(spacing: 10) {
            part("in", counts.input)
            part("out", counts.output)
            part("cache write", counts.cacheCreation)
            part("cache read", counts.cacheRead)
        }
        .help("The last 5 hours, by kind. Cache reads are most of any total.")
    }

    private func part(_ label: String, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(Ink.tertiary)
            Text(TokenUsageText.compact(count))
                .foregroundStyle(Ink.secondary)
        }
        .font(.scopeCaption.monospacedDigit())
        .lineLimit(1)
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Text("5h")
                    .frame(width: 44, alignment: .trailing)
                Text("7d")
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.scopeMicro)
            .foregroundStyle(Ink.tertiary)
            rows()
        }
    }

    private func pairRow(_ title: String, detail: String?, _ windows: TokenWindows) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.scopeRow)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(TokenUsageText.compact(windows.fiveHours.counts.total))
                .frame(width: 44, alignment: .trailing)
            Text(TokenUsageText.compact(windows.sevenDays.counts.total))
                .foregroundStyle(Ink.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.scopeRow.monospacedDigit())
    }

    private func threadDetail(_ row: TokenUsageSnapshot.Row) -> String {
        if let task = row.task.flatMap(TaskID.init(rawValue:)).flatMap({ model.task($0) }) { return task.name }
        return model.tokenScopeName(row.scope)
    }

    private func dollars(_ window: TokenWindow) -> String {
        let cost = TokenPricing.dollars(byModel: window.byModel)
        // Always `$`, whatever the locale: these are US list prices, not an amount in the user's currency.
        return "$" + cost.dollars.formatted(.number.precision(.fractionLength(cost.dollars < 10 ? 2 : 0)))
            + (cost.unpriced.isEmpty ? "" : "+")
    }

    private func footnote(cost: Bool, limits: Bool) -> String {
        var text = "Tokens are read from Claude Code transcripts, subagents and cache reads included."
        text += limits
            ? " They say who spent the limits above; the limits themselves are Claude Code's figures."
            : " Your plan’s limit is not in them, so this is consumption, not what is left."
        if cost { text += " Dollars are API-equivalent list prices, not what a subscription is billed." }
        return text
    }
}
