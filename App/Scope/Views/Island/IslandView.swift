import ScopeAdapters
import ScopeControl
import ScopeCore
import SwiftUI

/// The island under the notch (spec §7). Collapsed, a band around the notch — or a pill where there is none — with the
/// number of threads at work, a dot per thread and the five-hour ring; open, the requests waiting on the user and the
/// threads by task; for a few seconds after a turn ends or a thread asks, the band grows to say so.
///
/// Around a notch the band is black, whatever the appearance: it has to read as the notch itself. Everything below it,
/// and the whole pill on a screen without a notch, is drawn with the app's own surfaces, light or dark.
struct IslandView: View {
    let layout: IslandLayout
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let wing: CGFloat = 64
    static let openWidth: CGFloat = 380
    static let alertWidth: CGFloat = 340
    static let radius: CGFloat = 14

    private var presentation: IslandModel.Presentation { model.island.presentation }

    var body: some View {
        VStack(spacing: 0) {
            band
            switch presentation {
            case .collapsed:
                EmptyView()
            case .expanded:
                IslandList()
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            case .alert(let alert):
                IslandAlertCard(alert: alert)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: width)
        .background(background)
        .clipShape(shape)
        .overlay { if !layout.onNotch || presentation != .collapsed { shape.strokeBorder(Surface.stroke, lineWidth: 1) } }
        .shadow(color: .black.opacity(presentation == .collapsed ? 0 : 0.16), radius: 8, y: 3)
        // Room for the shadow inside the window, which would otherwise cut it off in a hard edge.
        .padding(.horizontal, presentation == .collapsed ? 0 : 22)
        .padding(.bottom, presentation == .collapsed ? 0 : 26)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: presentation)
        .environment(\.colorScheme, layout.onNotch && presentation == .collapsed ? .dark : colorScheme)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var width: CGFloat {
        switch presentation {
        case .collapsed: layout.bandWidth + 2 * Self.wing + (layout.onNotch ? 0 : 10)
        case .expanded: max(Self.openWidth, layout.bandWidth + 2 * Self.wing)
        case .alert: max(Self.alertWidth, layout.bandWidth + 2 * Self.wing)
        }
    }

    private var shape: UnevenRoundedRectangle {
        let bottom = presentation == .collapsed ? (layout.onNotch ? 10 : layout.bandHeight / 2) : Self.radius
        // Flat on top: it hangs from the edge of the screen like the notch does.
        return UnevenRoundedRectangle(topLeadingRadius: layout.onNotch ? 0 : (presentation == .collapsed ? layout.bandHeight / 2 : 6),
                                      bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                                      topTrailingRadius: layout.onNotch ? 0 : (presentation == .collapsed ? layout.bandHeight / 2 : 6),
                                      style: .continuous)
    }

    @ViewBuilder private var background: some View {
        if layout.onNotch {
            VStack(spacing: 0) {
                Color.black.frame(height: layout.bandHeight)
                Surface.elevated
            }
        } else {
            Surface.elevated
        }
    }

    /// The collapsed content, which stays as the head of the open island: count and dots on the left of the notch,
    /// the ring on its right.
    private var band: some View {
        let snapshot = model.island.snapshot
        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                if snapshot.activeCount > 0 {
                    Text("\(snapshot.activeCount)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(layout.onNotch ? .white : Ink.primary)
                }
                HStack(spacing: 3) {
                    ForEach(Array(snapshot.dots.enumerated()), id: \.offset) { _, state in
                        StateDot(state: state, size: 6, pulses: state == .running)
                    }
                    if snapshot.overflow > 0 {
                        Text("+\(snapshot.overflow)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(layout.onNotch ? Color.white.opacity(0.7) : Ink.secondary)
                    }
                }
            }
            .frame(width: Self.wing + (layout.onNotch ? 0 : 6), alignment: layout.onNotch ? .center : .trailing)
            Spacer().frame(width: max(layout.bandWidth, layout.onNotch ? 0 : 10))
            Group {
                if let percentage = model.island.fiveHourPercentage {
                    LimitRing(percentage: percentage)
                        .frame(width: 13, height: 13)
                        .help("5-hour limit: \(Int(percentage.rounded())) % used")
                } else {
                    Color.clear.frame(width: 13, height: 13)
                }
            }
            .frame(width: Self.wing - (layout.onNotch ? 0 : 6), alignment: layout.onNotch ? .center : .leading)
        }
        .frame(height: layout.bandHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { IslandController.shared.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(snapshot))
        .accessibilityAddTraits(.isButton)
    }

    private func accessibilitySummary(_ snapshot: Island.Snapshot) -> String {
        var parts = ["\(snapshot.activeCount) active"]
        if !snapshot.requests.isEmpty { parts.append("\(snapshot.requests.count) waiting for you") }
        if let percentage = model.island.fiveHourPercentage { parts.append("5-hour limit \(Int(percentage.rounded())) % used") }
        return "Scope island: " + parts.joined(separator: ", ")
    }
}

/// The open island: requests first, then the threads by task, a row each.
private struct IslandList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.island.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let percentage = model.island.fiveHourPercentage {
                    usage(percentage)
                }
                if !snapshot.requests.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "Waiting for you")
                        ForEach(snapshot.requests) { row in IslandRequestRow(row: row) }
                    }
                }
                ForEach(snapshot.groups) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                            if let subtitle = group.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Ink.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 6)
                        ForEach(group.rows) { row in IslandThreadRow(row: row) }
                    }
                }
                if snapshot.isEmpty {
                    Text("Nothing running")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func usage(_ percentage: Double) -> some View {
        HStack(spacing: 8) {
            Text("5-hour limit")
                .font(.system(size: 11))
                .foregroundStyle(Ink.secondary)
            LimitBar(percentage: percentage)
            Text("\(Int(percentage.rounded())) %")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.secondary)
        }
        .padding(.horizontal, 6)
    }
}

/// One thread at work, finished or failed: its dot, title, what it does, how long; a click opens it in Scope.
private struct IslandThreadRow: View {
    let row: Island.Row
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button { model.openFromIsland(row.id) } label: {
            HStack(spacing: 8) {
                StateDot(state: row.isQuiet ? .idle : row.thread.state, size: 7, pulses: row.thread.state == .running && !row.isQuiet)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.thread.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(row.line)
                        .font(.system(size: 11))
                        .foregroundStyle(row.isQuiet ? PullRequestStyle.pending : Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                IslandElapsed(since: row.thread.since)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(hovering ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open in Scope")
    }
}

/// A thread waiting on the user: what it asks, and what can be answered from here.
private struct IslandRequestRow: View {
    let row: Island.Row
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StateDot(state: row.thread.state, size: 7)
                Text(row.thread.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let task = row.thread.taskName {
                    Text(task)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                IslandElapsed(since: row.thread.since)
            }
            asked
            if let plan = row.thread.request?.plan, row.thread.request?.kind == .plan {
                Text(Self.preview(plan))
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Fill.quiet, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let refusal = model.island.refusal, refusal.thread == row.id {
                Text(refusal.text)
                    .font(.system(size: 11))
                    .foregroundStyle(PullRequestStyle.failing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in button(action) }
            }
        }
        .padding(8)
        .background(Surface.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Surface.stroke, lineWidth: 1))
    }

    @ViewBuilder private var asked: some View {
        let request = row.thread.request
        if let command = request?.command, request?.kind == .permission {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Ink.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
        } else if request?.kind != .plan {
            Text(row.line)
                .font(.system(size: 11.5))
                .foregroundStyle(Ink.primary)
                .lineLimit(3)
        }
    }

    @ViewBuilder private func button(_ action: Island.Action) -> some View {
        switch action {
        case .allow:
            Button("Allow") { model.answerFromIsland(row.id, action: action) }.buttonStyle(.scopePrimary)
        case .deny:
            Button("Deny") { model.answerFromIsland(row.id, action: action) }.buttonStyle(.scopeSecondary)
        case .choose(_, let label):
            Button(label) { model.answerFromIsland(row.id, action: action) }.buttonStyle(.scopeSecondary).lineLimit(1)
        case .open:
            Button("Open") { model.openFromIsland(row.id) }.buttonStyle(.scopeGhost)
        }
    }

    /// The plan without its Markdown marks, enough to know what it is about before opening it.
    static func preview(_ plan: String) -> String {
        plan.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                var text = line
                while text.hasPrefix("#") { text.removeFirst() }
                if text.hasPrefix("- ") || text.hasPrefix("* ") { text = "• " + text.dropFirst(2) }
                return text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }
}

/// The reveal under the band: which thread, and what happened.
private struct IslandAlertCard: View {
    let alert: Island.Alert
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.island.presentation = .expanded } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(alert.title) · \(verb)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(alert.line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var verb: String {
        switch alert.kind {
        case .finished: "finished"
        case .failed: "failed"
        case .question: "asks you"
        case .permission: "needs permission"
        case .plan: "has a plan"
        }
    }

    private var symbol: String {
        switch alert.kind {
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .question: "questionmark.bubble.fill"
        case .permission: "lock.shield.fill"
        case .plan: "list.bullet.rectangle.fill"
        }
    }

    private var tint: Color {
        switch alert.kind {
        case .finished: ThreadStateStyle.done
        case .failed: ThreadStateStyle.failed
        case .question, .permission, .plan: ThreadStateStyle.waiting
        }
    }
}

/// `3 min`, ticking: a turn's length, how long a request has waited, since when a turn is over.
private struct IslandElapsed: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DurationText.short(context.date.timeIntervalSince(since)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }
}
