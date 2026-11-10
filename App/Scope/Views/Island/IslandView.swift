import ScopeAdapters
import ScopeControl
import ScopeCore
import SwiftUI

/// The island at the top of the screen (spec §7), black whatever the appearance: it hangs from the top edge like the
/// notch does, and on a screen with one it reads as the notch itself.
///
/// One shape, always: the capsule — or two wings either side of the notch, nothing ever under it — grows a little under
/// the pointer, widens to name a turn that ended, drops a card for a reveal, and opens on the list, each time by
/// resizing the same black outline on a spring. What it shows sits inside and is revealed as the outline grows, so the
/// content never scales and nothing pops in beside it. The band at the top — dots, counter, ring — stays where it is
/// through all of it.
struct IslandView: View {
    let layout: IslandLayout
    @Environment(AppModel.self) private var model

    var body: some View {
        let stage = layout.stage
        let corners = Island.corners(stage, bandHeight: layout.bandHeight, onNotch: layout.onNotch)
        let outline = IslandOutline(bottom: corners.bottom, shoulder: corners.shoulder)
        VStack(spacing: 0) {
            IslandBand(layout: layout)
            switch stage {
            case .notice:
                if case .alert(let alert) = layout.presentation {
                    IslandNotice(alert: alert)
                        .id(alert.key)
                        .transition(Self.content)
                }
            case .open:
                IslandList()
                    .transition(Self.content)
            case .collapsed, .peek, .compact:
                EmptyView()
            }
        }
        .padding(.horizontal, corners.shoulder)
        .clipShape(outline)
        .background {
            outline
                .fill(Color.black)
                .shadow(color: .black.opacity(stage == .open || stage == .notice ? 0.45 : 0), radius: 18, y: 8)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            IslandController.shared.shapeChanged(size)
        }
        .contentShape(outline)
        // A row coming or going in the open list, a counter changing: the outline follows, smoothly.
        .animation(.smooth(duration: 0.28), value: model.island.snapshot)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// The content of a card or the list: in once the outline has started to grow, out at once as it folds. The outline
    /// does the moving; the content only fades, with a short drop so it seems to come down with it.
    private static let content: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: -8)).animation(.easeOut(duration: 0.24).delay(0.06)),
        removal: .opacity.animation(.easeIn(duration: 0.1)))
}

/// The island's outline: flat on top where it meets the screen's edge, its two top corners flaring outwards the way the
/// notch meets the bezel, rounded below. The shoulders lie inside the frame, `shoulder` each side of the body, so the
/// content is padded by as much. Both radii animate: the shape changes size and character in one move.
struct IslandOutline: Shape {
    var bottom: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottom, shoulder) }
        set {
            bottom = newValue.first
            shoulder = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 4, rect.height / 2)
        let left = rect.minX + s, right = rect.maxX - s
        let r = min(bottom, (right - left) / 2, max(0, rect.height - s))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.minY + s), control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - r), control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The band at the top of the outline: the dots, the counter and the ring — around a notch, in two wings either side of
/// it — or, on a compact reveal, the thread that ended and how. It keeps its place whatever the outline does below it;
/// a click on it opens or closes the list.
private struct IslandBand: View {
    let layout: IslandLayout
    @Environment(AppModel.self) private var model
    private typealias Metrics = Island.Metrics

    var body: some View {
        let snapshot = model.island.snapshot
        let percentage = model.island.fiveHourPercentage
        let compact = compactAlert
        let peek = layout.stage == .peek
        Button { IslandController.shared.toggle() } label: {
            Group {
                if layout.stage == .open {
                    IslandHeader(layout: layout)
                        .transition(.opacity)
                } else if layout.onNotch {
                    let wing = compact == nil ? Island.wingWidth(snapshot, hasRing: percentage != nil) : Metrics.compactText
                    HStack(spacing: 0) {
                        Group {
                            if let compact { compactTitle(compact) } else { IslandDots(snapshot: snapshot) }
                        }
                        .frame(width: wing)
                        Color.clear.frame(width: layout.bandWidth)
                        Group {
                            if let compact {
                                compactOutcome(compact)
                            } else {
                                HStack(spacing: Metrics.gap) {
                                    counter(snapshot)
                                    if let percentage { IslandRing(percentage: percentage) }
                                }
                            }
                        }
                        .frame(width: wing)
                    }
                } else {
                    HStack(spacing: Metrics.gap) {
                        if let compact {
                            compactTitle(compact)
                            compactOutcome(compact)
                        } else {
                            IslandDots(snapshot: snapshot)
                            counter(snapshot)
                            if let percentage { IslandRing(percentage: percentage) }
                        }
                    }
                    .padding(.horizontal, Metrics.padding)
                }
            }
            .padding(.horizontal, peek ? Metrics.peekGrowth.width / 2 : 0)
            .frame(height: rowHeight, alignment: .center)
            .padding(.bottom, peek && layout.onNotch ? Metrics.peekGrowth.height : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Island.accessibilitySummary(snapshot, fiveHour: percentage))
        .accessibilityHint(model.island.presentation == .expanded ? "Closes the list" : "Opens the list of threads")
    }

    /// The capsule's own height, a little more under the pointer or as the open island's header.
    private var rowHeight: CGFloat {
        if layout.onNotch { return layout.bandHeight }
        if layout.stage == .open { return max(layout.bandHeight, 30) }
        return layout.bandHeight + (layout.stage == .peek ? Metrics.peekGrowth.height : 0)
    }

    /// The reveal the band names, when it is a compact one.
    private var compactAlert: Island.Alert? {
        guard layout.stage == .compact, case .alert(let alert) = layout.presentation else { return nil }
        return alert
    }

    private func counter(_ snapshot: Island.Snapshot) -> some View {
        Text(Island.counter(snapshot, onNotch: layout.onNotch))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(IslandInk.primary)
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
    }

    private func compactTitle(_ alert: Island.Alert) -> some View {
        HStack(spacing: 6) {
            IslandDot(state: alert.kind == .failed ? .failed : .done, size: 7)
            Text(alert.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IslandInk.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: layout.onNotch ? .trailing : .leading)
        .padding(.horizontal, layout.onNotch ? 10 : 0)
        .transition(.opacity)
    }

    private func compactOutcome(_ alert: Island.Alert) -> some View {
        Text(alert.kind == .failed ? "failed" : "finished")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(alert.kind == .failed ? IslandInk.failed : IslandInk.secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: layout.onNotch ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, layout.onNotch ? 10 : 0)
            .transition(.opacity)
    }
}

/// The band of the open island: how many threads in each state on one side, the five-hour and weekly limits on the
/// other — either side of the notch, or across the capsule.
private struct IslandHeader: View {
    let layout: IslandLayout
    @Environment(AppModel.self) private var model

    var body: some View {
        let width = Island.Metrics.openWidth
        if layout.onNotch {
            let side = (width - layout.bandWidth) / 2
            HStack(spacing: 0) {
                counts.frame(width: side - 16, alignment: .leading).padding(.leading, 16)
                Color.clear.frame(width: layout.bandWidth)
                limits.frame(width: side - 16, alignment: .trailing).padding(.trailing, 16)
            }
        } else {
            HStack {
                counts
                Spacer(minLength: 12)
                limits
            }
            .padding(.horizontal, 16)
            .frame(width: width)
        }
    }

    private var counts: some View {
        HStack(spacing: 10) {
            let counts = Island.stateCounts(model.island.snapshot)
            if counts.isEmpty {
                Text("Nothing running").font(.system(size: 11.5)).foregroundStyle(IslandInk.tertiary)
            }
            ForEach(counts, id: \.state) { entry in
                HStack(spacing: 4) {
                    IslandDot(state: entry.state, size: 7)
                    Text("\(entry.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(IslandInk.primary)
                        .contentTransition(.numericText())
                }
                .help("\(entry.count) \(entry.state.needsAttention ? "waiting for you" : entry.state.displayLabel.lowercased())")
            }
        }
        .lineLimit(1)
    }

    private var limits: some View {
        HStack(spacing: 10) {
            ForEach([("5h", model.island.fiveHour), ("7d", model.island.sevenDay)], id: \.0) { label, window in
                if let window {
                    HStack(spacing: 4) {
                        IslandRing(percentage: window.usedPercentage, size: 12, label: window.label)
                        Text(label)
                            .foregroundStyle(IslandInk.tertiary)
                        Text(RateLimitText.percent(window.usedPercentage))
                            .foregroundStyle(IslandInk.limit(window.usedPercentage))
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .help(window.resetsAt.map { "\(window.label): resets in " + RateLimitText.remaining(until: $0, now: .now) } ?? window.label)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: Notices

/// A reveal's card under the band: a request with what it asks and its buttons, until it is answered; a turn that ended,
/// for a few seconds — held while the pointer is on it, a click taking Scope to the thread.
private struct IslandNotice: View {
    let alert: Island.Alert
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.island.snapshot
        VStack(alignment: .leading, spacing: 0) {
            if alert.isRequest, let row = snapshot.requests.first(where: { $0.id == alert.thread }) {
                IslandRequest(row: row)
            } else {
                IslandTurnNotice(alert: alert, row: (snapshot.requests + snapshot.groups.flatMap(\.rows)).first { $0.id == alert.thread })
            }
            if model.island.queuedCount > 0 {
                Text(model.island.queuedCount == 1 ? "1 more" : "\(model.island.queuedCount) more")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandInk.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(width: Island.Metrics.widenedWidth)
    }
}

/// A turn that finished or failed: the thread, where it lives, how long it ran, what the agent said — enough to know
/// whether to go and look — and a hairline that runs out with the time left. A click opens the thread.
private struct IslandTurnNotice: View {
    let alert: Island.Alert
    let row: Island.Row?
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.openFromIsland(alert.thread) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    IslandBadge(thread: badgeThread, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(IslandInk.primary)
                            .lineLimit(1)
                        Text(context)
                            .font(.system(size: 11))
                            .foregroundStyle(IslandInk.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(alert.kind == .failed ? "Failed" : "Finished")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(alert.kind == .failed ? IslandInk.failed : IslandInk.of(.done))
                }
                if !alert.line.isEmpty {
                    Text(alert.line)
                        .font(.system(size: 12.5))
                        .foregroundStyle(IslandInk.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 38)
                }
                IslandCountdown()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
        .accessibilityHint("Opens the thread in Scope")
    }

    /// The row's thread, else one standing for the turn's outcome.
    private var badgeThread: Island.ThreadInput {
        if let row { return row.thread }
        return Island.ThreadInput(id: alert.thread, scopeID: ScopeID(rawValue: ""), scopeName: "", title: alert.title,
                                  state: alert.kind == .failed ? .failed : .done)
    }

    /// `task · scope · 4 min · 12 tools`.
    private var context: String {
        var parts: [String] = []
        if let row {
            if let task = row.thread.taskName { parts.append(task) }
            parts.append(row.thread.scopeName)
            if let summary = Island.turnSummary(length: row.thread.turnLength, tools: row.thread.turnTools) { parts.append(summary) }
        }
        return parts.joined(separator: " · ")
    }
}

/// The time a notice has left, as a hairline running out; full while the pointer holds the notice.
private struct IslandCountdown: View {
    @Environment(AppModel.self) private var model
    @State private var left: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(IslandInk.track)
                .frame(width: proxy.size.width * left)
        }
        .frame(height: 2)
        .padding(.leading, 38)
        .onAppear { run(model.island.noticeClock) }
        .onChange(of: model.island.noticeClock) { _, clock in run(clock) }
        .accessibilityHidden(true)
    }

    private func run(_ clock: IslandModel.NoticeClock?) {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { left = 1 }
        guard let clock else { return }
        let remaining = max(0, clock.ends.timeIntervalSinceNow)
        withAnimation(.linear(duration: remaining)) { left = 0 }
    }
}

/// Dims what is pressed, nothing else: the island's plain buttons answer the hand.
private struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
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
    var size: CGFloat = Island.Metrics.ring
    var label = "5-hour"

    var body: some View {
        let fraction = min(1, max(0, percentage / 100))
        ZStack {
            Circle().stroke(IslandInk.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(IslandInk.limit(percentage), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .help("\(label) limit: \(RateLimitText.percent(percentage)) used")
    }
}

/// A thread's badge in the open island and on its cards: the state's colour, tinted, and a symbol for what it does
/// or waits for (`Island.symbol`). The dots stay for the collapsed band, where room is a few points.
struct IslandBadge: View {
    let thread: Island.ThreadInput
    var quiet = false
    var size: CGFloat = 26

    var body: some View {
        let tint = quiet ? IslandInk.waiting : IslandInk.of(thread.state)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(tint.opacity(0.18))
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
            Image(systemName: quiet ? "moon.zzz.fill" : Island.symbol(thread))
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A small rounded label on black: a count of sub-agents, a task.
struct IslandChip: View {
    let text: String
    var symbol: String?
    var tint: Color = IslandInk.secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.07), in: Capsule())
        .fixedSize()
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
            HStack(spacing: 10) {
                IslandBadge(thread: row.thread, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandInk.primary)
                        .lineLimit(1)
                    Text(verb.prefix(1).uppercased() + verb.dropFirst() + " · " + (row.thread.taskName ?? row.thread.scopeName))
                        .font(.system(size: 11.5))
                        .foregroundStyle(IslandInk.waiting.opacity(0.9))
                        .lineLimit(1)
                }
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
            (Text(request?.command == nil ? "" : "$ ").foregroundStyle(IslandInk.tertiary) + Text(shown))
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
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(width: Island.Metrics.openWidth)
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
                HStack(alignment: .top, spacing: 10) {
                    IslandBadge(thread: row.thread, quiet: row.isQuiet)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.thread.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(IslandInk.primary)
                                .lineLimit(1)
                            if row.thread.agents > 0 {
                                IslandChip(text: "\(row.thread.agents)", symbol: "person.2.fill")
                                    .help(row.thread.agents == 1 ? "1 sub-agent running" : "\(row.thread.agents) sub-agents running")
                            }
                            Spacer(minLength: 6)
                            if hovering {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(IslandInk.secondary)
                                    .transition(.opacity)
                            } else {
                                IslandElapsed(since: row.thread.since)
                            }
                        }
                        Text(row.line)
                            .font(.system(size: 12))
                            .foregroundStyle(row.isQuiet ? IslandInk.waiting : IslandInk.secondary)
                            .lineLimit(row.thread.state == .done || row.thread.state == .failed ? 2 : 1)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the thread in Scope")
            if showsPlan, let plan = row.thread.plan, plan.total > 0 {
                IslandTodos(plan: plan)
                    .padding(.leading, 44)
                    .padding(.trailing, 6)
                    .padding(.bottom, 8)
            }
        }
        .background(hovering ? IslandInk.raised : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
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
