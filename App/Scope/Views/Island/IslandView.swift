import ScopeAdapters
import ScopeControl
import ScopeCore
import SwiftUI

/// The island at the top of the screen (spec §7), black whatever the appearance: it hangs from the top edge like the
/// notch does, and on a screen with one it reads as the notch itself.
///
/// Collapsed, a capsule centred under the edge — a dot per thread, `3 threads`, the five-hour ring — or, around a
/// notch, two wings either side of it, nothing ever under the notch. A request widens it unasked until it is answered;
/// a turn that ended widens it for a few seconds. Open, a card under it lists the requests, then the threads by task,
/// then the limits.
struct IslandView: View {
    let layout: IslandLayout
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Metrics = Island.Metrics
    /// Room around a card for its shadow inside the window, which would otherwise cut it off in a hard edge. None while
    /// collapsed: the window is exactly the capsule, and the menu bar beside it keeps its clicks.
    static let shadowRoom: CGFloat = 24

    private var presentation: IslandModel.Presentation { model.island.presentation }

    var body: some View {
        VStack(spacing: 0) {
            switch presentation {
            case .collapsed:
                collapsed
            case .expanded:
                collapsed
                IslandList()
                    .padding(.top, 8)
                    .padding(.horizontal, Self.shadowRoom)
                    .padding(.bottom, Self.shadowRoom)
                    .transition(transition)
            case .alert(let alert):
                IslandWidened(alert: alert, layout: layout)
                    .padding(.horizontal, Self.shadowRoom)
                    .padding(.bottom, Self.shadowRoom)
                    .transition(transition)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.3, dampingFraction: 0.8), value: presentation)
        .environment(\.colorScheme, .dark)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .top).combined(with: .opacity)
    }

    /// The capsule, or the wings around the notch: a button that opens the list, read by VoiceOver as one summary.
    private var collapsed: some View {
        let snapshot = model.island.snapshot
        let percentage = model.island.fiveHourPercentage
        return Button { IslandController.shared.toggle() } label: {
            Group {
                if layout.onNotch {
                    let wing = Island.wingWidth(snapshot, hasRing: percentage != nil)
                    HStack(spacing: 0) {
                        IslandDots(snapshot: snapshot).frame(width: wing)
                        Color.clear.frame(width: layout.bandWidth)
                        HStack(spacing: Metrics.gap) {
                            counter(snapshot, onNotch: true)
                            if let percentage { IslandRing(percentage: percentage) }
                        }
                        .frame(width: wing)
                    }
                } else {
                    HStack(spacing: Metrics.gap) {
                        IslandDots(snapshot: snapshot)
                        counter(snapshot, onNotch: false)
                        if let percentage { IslandRing(percentage: percentage) }
                    }
                    .padding(.horizontal, Metrics.padding)
                }
            }
            .frame(height: layout.bandHeight)
            .background(Color.black, in: IslandShape.hanging(radius: min(Metrics.collapsedRadius, layout.bandHeight / 2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Island.accessibilitySummary(snapshot, fiveHour: percentage))
        .accessibilityHint(presentation == .expanded ? "Closes the list" : "Opens the list of threads")
    }

    private func counter(_ snapshot: Island.Snapshot, onNotch: Bool) -> some View {
        Text(Island.counter(snapshot, onNotch: onNotch))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(IslandInk.primary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Flat on top, where it meets the edge of the screen; rounded below.
enum IslandShape {
    static func hanging(radius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius,
                               topTrailingRadius: 0, style: .continuous)
    }
}

/// The island's colours (`Island.Tint`): fixed, since its ground is black in light and dark alike.
enum IslandInk {
    static let primary = Color(islandTint: Island.Tint.primary)
    static let secondary = Color(islandTint: Island.Tint.secondary)
    static let tertiary = Color(islandTint: Island.Tint.tertiary)
    static let track = Color(islandTint: Island.Tint.track)
    static let requestCard = Color(islandTint: Island.Tint.requestCard)
    static let waiting = Color(islandTint: Island.Tint.waiting)
    static let failed = Color(islandTint: Island.Tint.failed)
    /// A hovered row, a command block.
    static let raised = Color(islandTint: 0x1C1C1E)

    static func of(_ state: ThreadState) -> Color {
        Island.Tint.of(state).map { Color(islandTint: $0) } ?? tertiary
    }

    static func limit(_ percentage: Double) -> Color {
        switch Island.limitTone(percentage) {
        case .normal: primary
        case .high: waiting
        case .exhausted: failed
        }
    }
}

extension Color {
    init(islandTint hex: Int) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// A thread's dot on black, in the shapes of `StateDot` — a square for waiting, a diamond for failed — so it reads
/// without its colour. Still: nothing on the island moves on its own.
struct IslandDot: View {
    let state: ThreadState
    var size: CGFloat = Island.Metrics.dot

    var body: some View {
        Group {
            switch state {
            case .waiting:
                RoundedRectangle(cornerRadius: size / 4, style: .continuous).fill(IslandInk.of(state))
            case .failed:
                RoundedRectangle(cornerRadius: size / 6, style: .continuous).fill(IslandInk.of(state))
                    .rotationEffect(.degrees(45))
                    .scaleEffect(0.8)
            default:
                Circle().fill(IslandInk.of(state))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.displayLabel)
    }
}

/// The collapsed dots, most urgent first, and the `+N` past six.
private struct IslandDots: View {
    let snapshot: Island.Snapshot

    var body: some View {
        HStack(spacing: Island.Metrics.dotSpacing) {
            ForEach(Array(snapshot.dots.enumerated()), id: \.offset) { _, state in IslandDot(state: state) }
            if snapshot.overflow > 0 {
                Text("+\(snapshot.overflow)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(IslandInk.secondary)
                    .fixedSize()
            }
        }
    }
}

/// The five-hour ring: a dark track, the share used in light, orange from 80 %, red once used up.
private struct IslandRing: View {
    let percentage: Double

    var body: some View {
        let fraction = min(1, max(0, percentage / 100))
        ZStack {
            Circle().stroke(IslandInk.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(IslandInk.limit(percentage), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: Island.Metrics.ring, height: Island.Metrics.ring)
        .help("5-hour limit: \(RateLimitText.percent(percentage)) used")
    }
}

// MARK: Widened

/// The island widened on one reveal: a request with what it asks and its buttons, until it is answered; a turn that
/// ended, for a few seconds. Around a notch it grows down from it, the wings kept in the band.
private struct IslandWidened: View {
    let alert: Island.Alert
    let layout: IslandLayout
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.island.snapshot
        VStack(alignment: .leading, spacing: 0) {
            if layout.onNotch {
                Color.clear.frame(height: layout.bandHeight)
            }
            Group {
                if alert.isRequest, let row = snapshot.requests.first(where: { $0.id == alert.thread }) {
                    IslandRequest(row: row)
                } else {
                    turn
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, layout.onNotch ? 4 : 10)
            .padding(.bottom, 12)
        }
        .frame(width: max(Island.Metrics.widenedWidth,
                          layout.bandWidth + 2 * Island.wingWidth(snapshot, hasRing: model.island.fiveHourPercentage != nil)))
        .background(Color.black, in: IslandShape.hanging(radius: 18))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    /// A turn that finished or failed: a click opens the list.
    private var turn: some View {
        Button { model.island.presentation = .expanded } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                IslandDot(state: alert.kind == .failed ? .failed : .done, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(alert.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IslandInk.primary)
                        Text("· " + (alert.kind == .failed ? "failed" : "finished"))
                            .font(.system(size: 12))
                            .foregroundStyle(IslandInk.secondary)
                    }
                    .lineLimit(1)
                    if !alert.line.isEmpty {
                        Text(alert.line)
                            .font(.system(size: 12))
                            .foregroundStyle(IslandInk.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the list of threads")
    }
}

// MARK: Requests

/// A thread waiting on the user: which one, what it asks — the command in full whenever Allow is offered — and what can
/// be answered from here, Allow last. Widened on black, or on an orange-tinted card at the top of the open list.
private struct IslandRequest: View {
    let row: Island.Row
    var inList = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IslandDot(state: row.thread.state, size: 8)
                Text(row.thread.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandInk.primary)
                    .lineLimit(1)
                Text("· " + verb)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandInk.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                IslandElapsed(since: row.thread.since)
            }
            asked
            if let refusal = model.island.refusal, refusal.thread == row.id {
                Text(refusal.text)
                    .font(.system(size: 12))
                    .foregroundStyle(IslandInk.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(Island.buttons(row.actions).enumerated()), id: \.offset) { _, action in button(action) }
            }
        }
    }

    private var verb: String {
        switch row.thread.request?.kind {
        case .permission?:
            switch row.thread.request?.tool {
            case "Bash"?: "wants to run"
            case let tool?: "wants to use \(tool)"
            case nil: "needs permission"
            }
        case .plan?: "has a plan"
        case .question?, .elicitation?: "asks you"
        case nil: row.thread.state == .waiting(reason: .permission) ? "needs permission" : "waits for you"
        }
    }

    @ViewBuilder private var asked: some View {
        let request = row.thread.request
        if request?.kind == .permission, let shown = request?.command ?? request?.filePath ?? request?.url {
            let whole = Island.showsCommandWhole(row)
            Text(shown)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(IslandInk.primary)
                .lineLimit(whole ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: whole)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(inList ? Color.black : IslandInk.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let plan = request?.plan, request?.kind == .plan {
            Text(IslandRequest.preview(plan))
                .font(.system(size: 12))
                .foregroundStyle(IslandInk.secondary)
                .lineLimit(inList ? 6 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(row.line)
                .font(.system(size: 12.5))
                .foregroundStyle(IslandInk.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func button(_ action: Island.Action) -> some View {
        switch action {
        case .allow:
            Button("Allow") { model.answerFromIsland(row.id, action: action) }.buttonStyle(IslandButtonStyle(prominent: true))
        case .deny:
            Button("Deny") { model.answerFromIsland(row.id, action: action) }.buttonStyle(IslandButtonStyle())
        case .choose(_, let label):
            Button(label) { model.answerFromIsland(row.id, action: action) }.buttonStyle(IslandButtonStyle()).lineLimit(1)
        case .open:
            Button("Open") { model.openFromIsland(row.id) }.buttonStyle(IslandButtonStyle())
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

/// The island's buttons: grey, Allow in the waiting orange with dark text — both well past 4.5:1.
private struct IslandButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color(islandTint: 0x1C1C1E) : IslandInk.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(prominent ? IslandInk.waiting : IslandInk.track,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: Open

/// The open island: requests first on orange-tinted cards, then the threads by task — the todo list under the one
/// hovered, or the one selected in Scope — and the five-hour and weekly limits at the foot.
private struct IslandList: View {
    @Environment(AppModel.self) private var model
    /// The row the pointer rested on, which shows its todo list. Set after a short rest and kept once the pointer
    /// leaves, so the list opening under one row never shifts the next under the pointer into a loop.
    @State private var focused: ThreadID?
    @State private var focusing: Task<Void, Never>?

    var body: some View {
        let snapshot = model.island.snapshot
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.requests) { row in
                        IslandRequest(row: row, inList: true)
                            .padding(12)
                            .background(IslandInk.requestCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    ForEach(snapshot.groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            header(group)
                            ForEach(group.rows) { row in
                                IslandThreadRow(row: row, showsPlan: row.id == (focused ?? model.selectedThreadID)) { inside in
                                    hovered(row.id, inside)
                                }
                            }
                        }
                    }
                    if snapshot.isEmpty {
                        Text("Nothing running")
                            .font(.system(size: 12))
                            .foregroundStyle(IslandInk.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            limits
        }
        .padding(14)
        .frame(width: Island.Metrics.openWidth)
        .background(Color.black, in: RoundedRectangle(cornerRadius: Island.Metrics.openRadius, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
    }

    private func header(_ group: Island.Group) -> some View {
        HStack(spacing: 6) {
            Text(group.title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(IslandInk.tertiary)
            if let subtitle = group.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandInk.tertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private func hovered(_ thread: ThreadID, _ inside: Bool) {
        guard inside else { return }
        focusing?.cancel()
        focusing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            focused = thread
        }
    }

    @ViewBuilder private var limits: some View {
        let windows = [("5 h", model.island.fiveHour), ("7 d", model.island.sevenDay)].compactMap { label, window in
            window.map { (label, $0) }
        }
        if !windows.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                ForEach(windows, id: \.0) { label, window in IslandLimit(label: label, window: window) }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
        }
    }
}

/// One limit at the foot of the open island: `5 h`, `12% · reset 3 h 07`, and its bar.
private struct IslandLimit: View {
    let label: String
    let window: RateLimits.Window

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                    Spacer(minLength: 6)
                    Text(detail(now: context.date)).monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(IslandInk.secondary)
                .lineLimit(1)
                GeometryReader { proxy in
                    Capsule()
                        .fill(IslandInk.limit(window.usedPercentage))
                        .frame(width: proxy.size.width * min(1, max(0, window.usedPercentage / 100)))
                }
                .frame(height: 4)
                .background(IslandInk.track, in: Capsule())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.label) limit: \(detail(now: context.date))")
        }
        .frame(maxWidth: .infinity)
    }

    private func detail(now: Date) -> String {
        var text = RateLimitText.percent(window.usedPercentage)
        if let resetsAt = window.resetsAt { text += " · reset " + RateLimitText.remaining(until: resetsAt, now: now) }
        return text
    }
}

/// One thread: its dot, title, what it does in grey, how long; a click opens it in Scope. Its todo list under it when
/// it is the one in focus.
private struct IslandThreadRow: View {
    let row: Island.Row
    let showsPlan: Bool
    let onHover: (Bool) -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.openFromIsland(row.id) } label: {
                HStack(spacing: 10) {
                    IslandDot(state: row.isQuiet ? .idle : row.thread.state, size: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.thread.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IslandInk.primary)
                        Text(row.line)
                            .font(.system(size: 12))
                            .foregroundStyle(row.isQuiet ? IslandInk.waiting : IslandInk.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 8)
                    IslandElapsed(since: row.thread.since)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the thread in Scope")
            if showsPlan, let plan = row.thread.plan, plan.total > 0 {
                IslandTodos(plan: plan)
                    .padding(.leading, 24)
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
            }
        }
        .background(hovering ? IslandInk.raised : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
    }
}

/// A thread's todo list: done, the one in progress, still to do; past eight, the count of the rest.
private struct IslandTodos: View {
    let plan: AgentPlan
    static let limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mark(step.status))
                        .foregroundStyle(step.status == .inProgress ? IslandInk.of(.running) : IslandInk.tertiary)
                        .frame(width: 10)
                    Text(step.label)
                        .foregroundStyle(step.status == .pending ? IslandInk.tertiary : IslandInk.secondary)
                        .strikethrough(step.status == .completed, color: IslandInk.tertiary)
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.label), \(spoken(step.status))")
            }
            if plan.steps.count > visible.count {
                Text("\(plan.steps.count - visible.count) more · \(plan.summary)")
                    .font(.system(size: 11))
                    .foregroundStyle(IslandInk.tertiary)
            }
        }
    }

    /// The window of eight around the step in progress, so the current one is always in sight.
    private var visible: [AgentPlan.Step] {
        guard plan.steps.count > Self.limit else { return plan.steps }
        let current = plan.steps.firstIndex { $0.status != .completed } ?? plan.steps.count - 1
        let start = min(max(0, current - 2), plan.steps.count - Self.limit)
        return Array(plan.steps[start..<start + Self.limit])
    }

    private func mark(_ status: AgentPlan.Status) -> String {
        switch status {
        case .completed: "✓"
        case .inProgress: "●"
        case .pending: "○"
        }
    }

    private func spoken(_ status: AgentPlan.Status) -> String {
        switch status {
        case .completed: "done"
        case .inProgress: "in progress"
        case .pending: "to do"
        }
    }
}

/// `3 min`: a turn's length, how long a request has waited, since when a turn is over. Read every half minute and
/// never finer than the minute, so nothing on the island ticks.
private struct IslandElapsed: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let seconds = context.date.timeIntervalSince(since)
                Text(seconds < 60 ? "now" : DurationText.short(seconds))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(IslandInk.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
