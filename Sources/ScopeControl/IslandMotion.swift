import Foundation
import ScopeCore

// MARK: The shape

extension Island {
    /// What the island's one black shape is doing. Every presentation is the same shape at another size: it grows out of
    /// the notch (or the capsule) and folds back into it, so nothing ever pops in beside it.
    public enum Stage: Sendable, Equatable {
        /// The capsule, or the wings around the notch.
        case collapsed
        /// The pointer rests on it: a little larger at once, before it opens — the first answer to the hand.
        case peek
        /// A turn that ended while the user works: the band widens to name it, no card.
        case compact
        /// A reveal's card under the band.
        case notice
        /// The list.
        case open
    }

    public static func stage(_ presentation: Presentation, hovering: Bool) -> Stage {
        switch presentation {
        case .collapsed: hovering ? .peek : .collapsed
        case .expanded: .open
        case .alert(let alert): alert.style == .compact ? (hovering ? .peek : .compact) : .notice
        }
    }

    /// The outline's corners. The top edge is flat against the screen's edge, and its two top corners curve *outwards*
    /// (`shoulder`), the way the notch itself meets the bezel: the shape reads as part of the screen, not as a badge laid
    /// on the menu bar.
    public struct Corners: Sendable, Equatable {
        public var bottom: CGFloat
        public var shoulder: CGFloat

        public init(bottom: CGFloat, shoulder: CGFloat) {
            self.bottom = bottom
            self.shoulder = shoulder
        }
    }

    /// The hardware notch's lower radius on the MacBook Pros, which the collapsed wings repeat so the three read as one.
    public static let notchRadius: CGFloat = 10

    public static func corners(_ stage: Stage, bandHeight: CGFloat, onNotch: Bool) -> Corners {
        switch stage {
        case .collapsed, .compact:
            // Around the notch, its own radius; a capsule is round below, as high as it is.
            Corners(bottom: onNotch ? notchRadius : bandHeight / 2, shoulder: 6)
        case .peek:
            Corners(bottom: onNotch ? notchRadius + 2 : (bandHeight + Metrics.peekGrowth.height) / 2, shoulder: 7)
        case .notice:
            Corners(bottom: 20, shoulder: 10)
        case .open:
            Corners(bottom: Metrics.openRadius, shoulder: 12)
        }
    }

    /// How much larger the collapsed shape grows under the pointer.
    public static func peekWidth(_ collapsedWidth: CGFloat) -> CGFloat { collapsedWidth + Metrics.peekGrowth.width }

    // MARK: The window

    /// The island's window never changes size: resizing a window under a running animation either cuts the animation
    /// short or makes it stutter, a frame late. It is as large as the open island and its shadow, hung from the top of
    /// the screen, centred on the band; outside the shape it lets every event through (`hitRect`).
    public static let panelSize = CGSize(width: 620, height: 700)

    public static func panelFrame(on screen: Screen) -> CGRect {
        let band = band(on: screen)
        let width = min(panelSize.width, screen.frame.width)
        let height = min(panelSize.height, screen.frame.height)
        let x = min(max(band.midX - width / 2, screen.frame.minX), screen.frame.maxX - width)
        return CGRect(x: x, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Where the shape of `size` stands on screen inside `panel`: hung from its top edge, centred on the band. This is
    /// the only part of the window that takes the pointer and the clicks — the shadow and the empty window around it
    /// leave them to the menu bar and the windows under it.
    public static func hitRect(shape size: CGSize, in panel: CGRect, bandMidX: CGFloat) -> CGRect {
        CGRect(x: bandMidX - size.width / 2, y: panel.maxY - size.height, width: size.width, height: size.height)
    }

    /// Whether the pointer at `point` is on the island. The collapsed shape is a thin strip at the very top of the screen,
    /// where the pointer is pushed against the edge: the top edge counts even a point above (the pointer stops at
    /// `maxY - 1`), and the sides a little wider than drawn, which a hand at speed needs.
    public static func isOver(_ point: CGPoint, hitRect: CGRect, stage: Stage) -> Bool {
        let slop: CGFloat = stage == .collapsed || stage == .compact ? 4 : 0
        return hitRect.insetBy(dx: -slop, dy: 0).insetBy(dx: 0, dy: -1).contains(point)
    }
}

// MARK: Motion

extension Island {
    /// A spring as SwiftUI takes it: how long one oscillation lasts, and how much of the bounce is damped (1 = none).
    public struct Spring: Sendable, Equatable {
        public var response: Double
        public var damping: Double
    }

    /// The springs the island moves with. Opening and revealing are quick with a hint of bounce — the shape lands —
    /// closing is a little slower and never overshoots: a fold that bounced back out would read as a second opening.
    /// Measured on the reference app at 60 fps: about 0.15 s to its full width, a settle, then a fold of about 0.45 s.
    public enum Motion {
        public static let open = Spring(response: 0.38, damping: 0.78)
        public static let notice = Spring(response: 0.42, damping: 0.8)
        public static let peek = Spring(response: 0.25, damping: 0.7)
        public static let close = Spring(response: 0.36, damping: 1)
    }

    /// Which spring takes the shape from one stage to the next.
    public static func spring(from old: Stage, to new: Stage) -> Spring {
        func size(_ stage: Stage) -> Int {
            switch stage {
            case .collapsed: 0
            case .compact, .peek: 1
            case .notice: 2
            case .open: 3
            }
        }
        if size(new) < size(old) { return Motion.close }
        switch new {
        case .open: return Motion.open
        case .notice: return Motion.notice
        case .peek, .compact, .collapsed: return Motion.peek
        }
    }
}

// MARK: Reveals, one after the other

extension Island {
    /// How a reveal shows.
    public enum AlertStyle: Sendable, Equatable {
        /// A card under the band, with what the agent said.
        case card
        /// The band only widens to name the thread: a turn that ended while the user works, which must not cover what
        /// they look at, and must not go unseen either.
        case compact
    }

    /// How long a reveal stays when nothing holds it: long enough to read what is written on it. A compact one is a
    /// glance; a card a few seconds more per line of text, up to a bound. A request has none — it stays until answered.
    public static func noticeDuration(_ alert: Alert) -> TimeInterval? {
        guard !alert.isRequest else { return nil }
        if alert.style == .compact { return 3.5 }
        let base: TimeInterval = alert.kind == .failed ? 7 : 6
        return min(10, base + Double(alert.line.count / 80))
    }

    /// After the pointer leaves a reveal it held: the rest of its time, but never so little it vanishes under the hand
    /// that just left it.
    public static let lingerAfterHover: TimeInterval = 2.5

    /// Reveals waiting their turn. Two turns that end together were two notices, of which only the last played; now
    /// they show one after the other — a request before a failure before a finished turn, the oldest first within each —
    /// and a thread that ends again while queued keeps one place, with its latest news.
    public struct AlertQueue: Sendable, Equatable {
        public private(set) var pending: [Alert] = []

        public init() {}

        public var isEmpty: Bool { pending.isEmpty }
        public var count: Int { pending.count }

        public mutating func push(_ alert: Alert) {
            if let index = pending.firstIndex(where: { $0.thread == alert.thread }) {
                pending[index] = alert
            } else {
                pending.append(alert)
            }
            // Stable: insertion order within a rank.
            pending = pending.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element)
        }

        /// The next reveal still worth showing against `snapshot`: a queued request already answered, or a turn whose
        /// thread is gone from the island, is dropped.
        public mutating func next(in snapshot: Snapshot) -> Alert? {
            while !pending.isEmpty {
                let alert = pending.removeFirst()
                if Island.isStillNews(alert, in: snapshot) { return alert }
            }
            return nil
        }

        /// Drops what the user has seen another way — the thread opened in Scope.
        public mutating func remove(thread: ThreadID) {
            pending.removeAll { $0.thread == thread }
        }

        private func rank(_ alert: Alert) -> Int {
            if alert.isRequest { return 0 }
            return alert.kind == .failed ? 1 : 2
        }
    }

    /// Whether a reveal still says something true: a request still waiting, a turn whose thread still shows as ended.
    public static func isStillNews(_ alert: Alert, in snapshot: Snapshot) -> Bool {
        if alert.isRequest { return settle(.alert(alert), snapshot: snapshot) != .collapsed }
        let rows = snapshot.requests + snapshot.groups.flatMap(\.rows)
        guard let row = rows.first(where: { $0.id == alert.thread }) else { return false }
        return alert.kind == .failed ? row.thread.state == .failed : row.thread.state == .done
    }

    /// What a new reveal does, given what the island shows: it plays now, waits in the queue, or — the list open —
    /// nothing at all, since the list already shows it.
    public enum Arrival: Sendable, Equatable {
        case show
        case queue
        case drop
    }

    public static func arrival(of alert: Alert, over presentation: Presentation, hovering: Bool) -> Arrival {
        switch presentation {
        case .expanded:
            return .drop
        case .collapsed:
            return .show
        case .alert(let current):
            // A request pushes a turn's notice aside — it comes back after; a turn never pushes a request.
            if alert.isRequest && !current.isRequest { return hovering ? .queue : .show }
            if current.isRequest { return .queue }
            // The one being read stays; another turn's notice waits for it.
            if hovering || current.style == .card { return .queue }
            return .show
        }
    }
}

// MARK: The line of a notice

extension Island {
    /// Under a finished turn's title: how long it ran and how many tools it called, when known — `4 min · 12 tools`.
    public static func turnSummary(length: TimeInterval?, tools: Int?) -> String? {
        var parts: [String] = []
        if let length, length >= 1 { parts.append(DurationText.short(length)) }
        if let tools, tools > 0 { parts.append(tools == 1 ? "1 tool" : "\(tools) tools") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: Badges

extension Island {
    /// The SF Symbol on a thread's badge: what it waits for, how its turn ended, or — running — what kind of work its
    /// last tool does, so a glance down the list says who edits, who runs commands, who searches, who thinks.
    public static func symbol(_ thread: ThreadInput) -> String {
        switch thread.state {
        case .waiting:
            switch thread.request?.kind {
            case .question?, .elicitation?: return "questionmark.bubble.fill"
            case .plan?: return "list.bullet.clipboard.fill"
            case .permission?, nil: return "hand.raised.fill"
            }
        case .failed: return "exclamationmark.triangle.fill"
        case .done: return "checkmark"
        case .idle, .exited: return "moon.zzz.fill"
        case .running:
            switch thread.tool {
            case nil: return "sparkles"
            case "Bash", "BashOutput", "KillShell": return "terminal.fill"
            case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
            case "Read": return "doc.text.fill"
            case "Grep", "Glob", "LS": return "magnifyingglass"
            case "WebFetch", "WebSearch": return "globe"
            case "Task", "Agent": return "person.2.fill"
            case "TodoWrite": return "checklist"
            case let tool? where tool.hasPrefix("mcp__"): return "puzzlepiece.extension.fill"
            default: return "wrench.and.screwdriver.fill"
            }
        }
    }

    /// The open island's header, beside the notch or across the capsule: how many threads in each state, most urgent
    /// first, zeros left out.
    public static func stateCounts(_ snapshot: Snapshot) -> [(state: ThreadState, count: Int)] {
        let states = (snapshot.requests + snapshot.groups.flatMap(\.rows)).map(\.thread.state)
        var counts: [(ThreadState, Int)] = []
        for state in [ThreadState.waiting(reason: .permission), .failed, .running, .done] {
            let count = states.filter { state.needsAttention ? $0.needsAttention : $0 == state }.count
            if count > 0 { counts.append((state, count)) }
        }
        return counts.map { (state: $0.0, count: $0.1) }
    }
}
