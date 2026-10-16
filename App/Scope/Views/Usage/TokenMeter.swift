import SwiftUI
import ScopeAdapters
import ScopeControl
import ScopeCore
import ScopeTasks

/// The toolbar's token meter: what Claude Code threads consumed over the last five hours, every scope together, and a
/// popover with the week, each scope and the threads that spent most.
///
/// Consumption only. The plan's limit is not in the transcripts, so there is no percentage — unless the user typed a
/// budget of their own (Settings ▸ General ▸ Token usage), which turns the label into a small gauge against it.
struct TokenMeterToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        let usage = model.tokenUsage
        if model.config.preferences.showTokenMeter, usage.hasUsage {
            let windows = usage.snapshot.all
            let budget = model.config.preferences.tokenBudgetPer5h
            Button {
                shown.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "circle.dotted.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                    Text(TokenUsageText.compact(windows.fiveHours.counts.total))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Ink.primary)
                    Text("5h")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                    if budget > 0 {
                        TokenGauge(used: windows.fiveHours.counts.total, budget: budget)
                            .frame(width: 28)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.scopeGhost)
            .help("Tokens Claude Code threads consumed in the last 5 hours — \(TokenUsageText.compact(windows.sevenDays.counts.total)) over 7 days")
            .accessibilityLabel("Tokens: \(TokenUsageText.compact(windows.fiveHours.counts.total)) in the last 5 hours")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                TokenUsagePopover()
            }
        }
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

/// The meter's breakdown: the three windows, what the five hours are made of, then each scope and the top threads.
struct TokenUsagePopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.tokenUsage.snapshot
        let preferences = model.config.preferences
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens")
                    .font(.scopeTitle)
                Spacer()
                Text("Claude Code threads")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            }

            VStack(spacing: 4) {
                if preferences.showAPICost {
                    HStack {
                        Spacer()
                        Text("API-equivalent")
                        Text("tokens")
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .font(.scopeMicro)
                    .foregroundStyle(Ink.tertiary)
                    .textCase(.uppercase)
                }
                windowRow("Last 5 hours", snapshot.all.fiveHours, budget: preferences.tokenBudgetPer5h, cost: preferences.showAPICost)
                windowRow("Today", snapshot.all.today, cost: preferences.showAPICost)
                windowRow("Last 7 days", snapshot.all.sevenDays, cost: preferences.showAPICost)
            }

            breakdown(snapshot.all.fiveHours.counts)

            let scopes = snapshot.scopes.values.filter { !$0.windows.sevenDays.counts.isZero }
                .sorted { ($0.windows.fiveHours.counts.total, $0.windows.sevenDays.counts.total) > ($1.windows.fiveHours.counts.total, $1.windows.sevenDays.counts.total) }
            if !scopes.isEmpty {
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
            Text(footnote(cost: preferences.showAPICost))
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
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

    private func footnote(cost: Bool) -> String {
        var text = "Read from Claude Code transcripts, subagents and cache reads included. Your plan’s limit is not in them, so this is consumption, not what is left."
        if cost { text += " Dollars are API-equivalent list prices, not what a subscription is billed." }
        return text
    }
}
