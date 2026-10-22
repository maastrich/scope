import Foundation
import ScopeAdapters
import ScopeCore

/// What the island under the notch shows (spec §7), worked out from the threads the app holds.
///
/// Pure: the app hands in one `ThreadInput` per thread whose driver reports its turns, already reconciled (the state
/// is `ThreadSession.displayState`, the request the one `pendingRequest(of:)` keeps, so a permission decided
/// elsewhere or a turn whose end hook was lost never reaches here as live), and gets back the collapsed summary, the
/// open list and the reveals to play.
public enum Island {
    /// How long a running thread may go without any event before its row says so: a lost end-of-turn hook shows as a
    /// thread "running" forever, and the island is where that would be the most visible.
    public static let quietAfter: TimeInterval = 10 * 60
    /// Most state dots the collapsed island draws; the rest is a `+N`.
    public static let dotLimit = 6

    /// One thread as the app sees it.
    public struct ThreadInput: Sendable, Equatable, Identifiable {
        public var id: ThreadID
        public var scopeID: ScopeID
        public var scopeName: String
        /// `TaskID.rawValue`: the package part this lives in does not know tasks.
        public var taskID: String?
        public var taskName: String?
        public var title: String
        public var state: ThreadState
        /// What it is doing, as the sidebar words it (`ThreadActivityHeadline.text`): `Running swift test`.
        public var activity: String?
        /// When the current state began: the turn's start, the request, the end of the turn.
        public var since: Date?
        /// The last time the driver said anything, for `quietAfter`.
        public var lastEventAt: Date?
        /// Sub-agents or background work still going: a long silence is then normal.
        public var hasBackgroundWork: Bool
        /// What a waiting Claude Code thread asks, when the app knows.
        public var request: ClaudePendingRequest?
        /// The thread the user is looking at in Scope right now (app frontmost, thread selected): never revealed.
        public var isForeground: Bool
        /// Moves with each turn (`ThreadSession.turnRevision`), so two turns ending alike are two reveals.
        public var turn: Int
        /// The agent's todo list or plan, shown under its row in the open island.
        public var plan: AgentPlan?

        public init(id: ThreadID, scopeID: ScopeID, scopeName: String, taskID: String? = nil, taskName: String? = nil,
                    title: String, state: ThreadState, activity: String? = nil, since: Date? = nil,
                    lastEventAt: Date? = nil, hasBackgroundWork: Bool = false, request: ClaudePendingRequest? = nil,
                    isForeground: Bool = false, turn: Int = 0, plan: AgentPlan? = nil) {
            self.id = id
            self.scopeID = scopeID
            self.scopeName = scopeName
            self.taskID = taskID
            self.taskName = taskName
            self.title = title
            self.state = state
            self.activity = activity
            self.since = since
            self.lastEventAt = lastEventAt
            self.hasBackgroundWork = hasBackgroundWork
            self.request = request
            self.isForeground = isForeground
            self.turn = turn
            self.plan = plan
        }
    }

    /// One row of the open island.
    public struct Row: Sendable, Equatable, Identifiable {
        public var thread: ThreadInput
        /// The line under the title: what it asks, what it does, how its turn ended.
        public var line: String
        /// Running, yet nothing heard for `quietAfter`: the row says so rather than claim the thread is at work.
        public var isQuiet: Bool
        /// What the row offers, in order. Empty for a thread that asks nothing.
        public var actions: [Action]

        public var id: ThreadID { thread.id }
    }

    /// The threads of one task, or of a scope's root when they belong to no task.
    public struct Group: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        /// The scope's name, under a task's.
        public var subtitle: String?
        public var rows: [Row]
    }

    /// What a request's row lets the user do from the island. None of them loses work: Allow is offered only when the
    /// island shows the whole of what is allowed, and nothing stops, closes or archives.
    public enum Action: Sendable, Equatable {
        case allow
        case deny
        /// A single-choice question's option: its index and label.
        case choose(Int, String)
        /// Brings Scope up on the thread.
        case open
    }

    /// Everything the island draws.
    public struct Snapshot: Sendable, Equatable {
        /// Threads running or waiting.
        public var activeCount: Int
        /// One dot per thread shown, most urgent first, at most `dotLimit`.
        public var dots: [ThreadState]
        public var overflow: Int
        /// The state that colours the collapsed shape: the most urgent of all.
        public var dominant: ThreadState?
        /// Threads waiting on the user, oldest request first: the top of the open island.
        public var requests: [Row]
        /// Every other thread shown, by task.
        public var groups: [Group]

        /// Nothing worth a surface: the island hides.
        public var isEmpty: Bool { requests.isEmpty && groups.isEmpty }

        /// Every thread the island shows — one dot each, drawn or counted in the `+N` — which is what its counter says:
        /// a count of running threads beside dots that also stand for finished ones read as a stray digit.
        public var shownCount: Int { dots.count + overflow }

        public static let empty = Snapshot(activeCount: 0, dots: [], overflow: 0, dominant: nil, requests: [], groups: [])
    }

    /// Longest command or path Allow is offered for: past it the row is cut, and the user would allow what they did
    /// not read.
    public static let allowableLength = 120

    /// Which threads show: running, waiting, and turns that ended unread. Idle and exited ones do not.
    public static func isShown(_ state: ThreadState) -> Bool {
        switch state {
        case .running, .waiting, .done, .failed: true
        case .idle, .exited: false
        }
    }

    public static func snapshot(_ threads: [ThreadInput], now: Date = .now) -> Snapshot {
        let shown = threads.filter { isShown($0.state) }
        guard !shown.isEmpty else { return .empty }
        let rows = shown.map { row($0, now: now) }
        let requests = rows.filter { $0.thread.state.needsAttention }
            .sorted { ($0.thread.request?.askedAt ?? $0.thread.since ?? .distantPast) < ($1.thread.request?.askedAt ?? $1.thread.since ?? .distantPast) }
        let rest = rows.filter { !$0.thread.state.needsAttention }
        var groups: [String: Group] = [:]
        var order: [String] = []
        for row in rest {
            let key = row.thread.taskID.map { "task:\($0)" } ?? "scope:\(row.thread.scopeID.rawValue)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = Group(id: key, title: row.thread.taskName ?? row.thread.scopeName,
                                    subtitle: row.thread.taskID == nil ? nil : row.thread.scopeName, rows: [])
            }
            groups[key]?.rows.append(row)
        }
        let sortedGroups = order.compactMap { groups[$0] }.map { group in
            var group = group
            group.rows.sort(by: rowOrder)
            return group
        }.sorted { lhs, rhs in
            let left = lhs.rows.first.map(rank) ?? 0, right = rhs.rows.first.map(rank) ?? 0
            if left != right { return left > right }
            return (lhs.rows.first?.thread.since ?? .distantPast) > (rhs.rows.first?.thread.since ?? .distantPast)
        }
        let states = shown.map(\.state).sorted { urgency($0) > urgency($1) }
        return Snapshot(activeCount: shown.filter { $0.state == .running || $0.state.needsAttention }.count,
                        dots: Array(states.prefix(dotLimit)), overflow: max(0, states.count - dotLimit),
                        dominant: ThreadState.mostUrgent(states), requests: requests, groups: sortedGroups)
    }

    static func row(_ thread: ThreadInput, now: Date) -> Row {
        let quiet = thread.state == .running && !thread.hasBackgroundWork
            && (thread.lastEventAt.map { now.timeIntervalSince($0) > quietAfter } ?? false)
        return Row(thread: thread, line: line(thread, quiet: quiet, now: now), isQuiet: quiet, actions: actions(thread))
    }

    static func line(_ thread: ThreadInput, quiet: Bool, now: Date) -> String {
        if thread.state.needsAttention, let request = thread.request { return request.headline }
        if quiet, let last = thread.lastEventAt {
            return "No news for \(DurationText.short(now.timeIntervalSince(last)))"
        }
        if let activity = thread.activity, !activity.isEmpty { return activity }
        return thread.state.label
    }

    /// Allow / Deny for a permission the island shows whole, a question's options when it is one single choice,
    /// and Open for every request: a plan, a form, a multiple choice and a long command are answered in Scope.
    public static func actions(_ thread: ThreadInput) -> [Action] {
        guard thread.state.needsAttention else { return [] }
        guard let request = thread.request else { return [.open] }
        switch request.kind {
        case .permission where ClaudeDialogAnswer.isAnswerable(request) && showsWhole(request):
            return [.allow, .deny, .open]
        case .permission where ClaudeDialogAnswer.isAnswerable(request):
            return [.deny, .open]
        case .question where ClaudeDialogAnswer.isAnswerable(request) && request.questions.count == 1
            && !request.questions[0].multiSelect:
            return request.questions[0].options.prefix(4).enumerated().map { .choose($0.offset, $0.element.label) } + [.open]
        default:
            return [.open]
        }
    }

    /// The island words a permission on one line: a command of several lines, or a long one, is not shown whole.
    public static func showsWhole(_ request: ClaudePendingRequest) -> Bool {
        let shown = request.command ?? request.filePath ?? request.url ?? request.headline
        return !shown.contains(where: \.isNewline) && shown.count <= allowableLength
    }

    private static func rowOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        let left = rank(lhs), right = rank(rhs)
        if left != right { return left > right }
        return (lhs.thread.since ?? .distantPast) > (rhs.thread.since ?? .distantPast)
    }

    private static func rank(_ row: Row) -> Int { urgency(row.thread.state) }

    /// `ThreadState.mostUrgent`'s order, which is the sidebar's.
    static func urgency(_ state: ThreadState) -> Int {
        switch state {
        case .exited: 0
        case .idle: 1
        case .done: 2
        case .running: 3
        case .failed: 4
        case .waiting(.input): 5
        case .waiting(.permission): 6
        }
    }
}

// MARK: Reveals

extension Island {
    /// What a reveal is about, which is also which sound it plays.
    public enum AlertKind: String, Sendable, Equatable, CaseIterable {
        case finished
        case failed
        case question
        case permission
        case plan
    }

    /// One reveal: the island grows for a moment to say it, with a sound when the settings want one.
    public struct Alert: Sendable, Equatable {
        /// Says what the reveal is for, so the same question, the same permission or the same turn reveals once.
        public var key: String
        public var kind: AlertKind
        public var thread: ThreadID
        public var title: String
        public var line: String
        /// The request revealed, for a question, a permission or a plan: the island stays widened on it until it is
        /// answered.
        public var requestID: String?

        public init(key: String, kind: AlertKind, thread: ThreadID, title: String, line: String, requestID: String? = nil) {
            self.key = key
            self.kind = kind
            self.thread = thread
            self.title = title
            self.line = line
            self.requestID = requestID
        }

        /// An agent blocked on the user, as opposed to a turn that ended.
        public var isRequest: Bool { kind != .finished && kind != .failed }
    }

    /// Why the island stays still right now, whatever happens: the user's Focus, a locked or sleeping screen. And
    /// whether the user is at work, which holds back the reveals `IslandSettings.interruptions` leaves out.
    public struct Quiet: Sendable, Equatable {
        public var focus: Bool
        public var screenLocked: Bool
        /// A key, a click or the pointer moved within `recentInput`.
        public var userActive: Bool

        public init(focus: Bool = false, screenLocked: Bool = false, userActive: Bool = false) {
            self.focus = focus
            self.screenLocked = screenLocked
            self.userActive = userActive
        }

        public var isQuiet: Bool { focus || screenLocked }

        /// How recent the last input must be for the user to count as at work: long enough to cover a pause to read,
        /// short enough that a reveal is not lost on someone who stepped back to wait.
        public static let recentInput: TimeInterval = 30

        /// Whether a reveal of `kind` may interrupt now.
        public func allows(_ kind: AlertKind, _ interruptions: IslandSettings.Interruptions) -> Bool {
            guard userActive else { return true }
            switch interruptions {
            case .never: return false
            case .requests: return kind != .finished && kind != .failed
            case .always: return true
            }
        }
    }

    /// The keys already revealed, oldest first, bounded: a request that comes back after a blip (`waiting` → `running`
    /// → `waiting` on the same permission) is not news a second time.
    public struct AlertMemory: Sendable, Equatable {
        public static let limit = 256
        public private(set) var keys: [String] = []

        public init() {}

        public func contains(_ key: String) -> Bool { keys.contains(key) }

        mutating func insert(_ key: String) {
            guard !keys.contains(key) else { return }
            keys.append(key)
            if keys.count > Self.limit { keys.removeFirst(keys.count - Self.limit) }
        }
    }

    /// The reveals between two readings of the threads. A thread only reveals what changed since `previous`: the first
    /// reading after launch, or a thread just restored, reveals nothing. A reveal skipped — the thread is in front, the
    /// Mac is quiet, the user is at work and may not be interrupted for it, the settings leave that kind out — is still
    /// remembered, so it does not burst out later when the
    /// Focus ends or the user looks elsewhere.
    public static func alerts(from previous: [ThreadInput], to current: [ThreadInput], settings: IslandSettings,
                              quiet: Quiet, memory: inout AlertMemory) -> [Alert] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var alerts: [Alert] = []
        for thread in current {
            guard let old = before[thread.id], let (kind, key) = change(from: old, to: thread),
                  !memory.contains(key) else { continue }
            memory.insert(key)
            guard !quiet.isQuiet, !thread.isForeground, wants(kind, settings),
                  quiet.allows(kind, settings.interruptions) else { continue }
            let line = thread.request.map(\.headline) ?? thread.activity ?? thread.state.label
            alerts.append(Alert(key: key, kind: kind, thread: thread.id, title: thread.title, line: line,
                                requestID: thread.state.needsAttention ? thread.request?.id : nil))
        }
        return alerts
    }

    static func change(from old: ThreadInput, to new: ThreadInput) -> (AlertKind, String)? {
        let id = new.id.rawValue
        switch new.state {
        case .waiting(let reason):
            // The request is what is new, not the state: a second permission while still waiting is a second reveal.
            if let request = new.request {
                guard old.request?.id != request.id || !old.state.needsAttention else { return nil }
                let kind: AlertKind = switch request.kind {
                case .permission: .permission
                case .plan: .plan
                case .question, .elicitation: .question
                }
                return (kind, "\(id)|request|\(request.id)")
            }
            guard !old.state.needsAttention else { return nil }
            return (reason == .permission ? .permission : .question, "\(id)|wait|\(new.turn)|\(new.since?.timeIntervalSince1970 ?? 0)")
        case .done where old.state == .running || old.state.needsAttention:
            return (.finished, "\(id)|done|\(new.turn)")
        case .failed where old.state != .failed:
            return (.failed, "\(id)|failed|\(new.turn)")
        default:
            return nil
        }
    }

    static func wants(_ kind: AlertKind, _ settings: IslandSettings) -> Bool {
        switch kind {
        case .finished: settings.alertsOnFinish
        case .failed: settings.alertsOnFailure
        case .question, .permission, .plan: settings.alertsOnRequest
        }
    }
}

// MARK: Where it sits

extension Island {
    /// One screen as the app reads it off `NSScreen`, in the global coordinates AppKit uses (origin bottom left).
    public struct Screen: Sendable, Equatable {
        public var name: String
        public var frame: CGRect
        /// `safeAreaInsets.top`: the notch's height on a screen that has one, 0 otherwise.
        public var safeTop: CGFloat
        /// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: the menu bar on either side of the notch.
        public var auxiliaryLeft: CGRect?
        public var auxiliaryRight: CGRect?
        /// The menu bar's height, from `visibleFrame`; 0 when it hides.
        public var menuBarHeight: CGFloat
        public var isMain: Bool

        public init(name: String, frame: CGRect, safeTop: CGFloat = 0, auxiliaryLeft: CGRect? = nil,
                    auxiliaryRight: CGRect? = nil, menuBarHeight: CGFloat = 0, isMain: Bool = false) {
            self.name = name
            self.frame = frame
            self.safeTop = safeTop
            self.auxiliaryLeft = auxiliaryLeft
            self.auxiliaryRight = auxiliaryRight
            self.menuBarHeight = menuBarHeight
            self.isMain = isMain
        }

        /// The notch, between the two auxiliary areas; `nil` on a screen without one.
        public var notch: CGRect? {
            guard safeTop > 0, let left = auxiliaryLeft, let right = auxiliaryRight, right.minX > left.maxX else { return nil }
            return CGRect(x: left.maxX, y: frame.maxY - safeTop, width: right.minX - left.maxX, height: safeTop)
        }
    }

    /// The screen the settings point at: the one named, the one holding most of `activeWindow`, the one under the
    /// pointer, else the main one. `activeWindow` is the frontmost window of the active app in AppKit coordinates,
    /// `nil` when that app shows none (Finder over the desktop, an app without windows): the pointer's screen then.
    public static func screen(_ screens: [Screen], settings: IslandSettings, pointer: CGPoint,
                              activeWindow: CGRect? = nil) -> Screen? {
        switch settings.placement {
        case .named:
            if let name = settings.screenName, let named = screens.first(where: { $0.name == name }) { return named }
        case .activeWindow:
            if let window = activeWindow, let holding = screen(holdingMostOf: window, among: screens) { return holding }
            if let under = screens.first(where: { $0.frame.contains(pointer) }) { return under }
        case .pointer:
            if let under = screens.first(where: { $0.frame.contains(pointer) }) { return under }
        case .main:
            break
        }
        return screens.first(where: \.isMain) ?? screens.first
    }

    /// The screen covering the largest area of `window`, the first one on a tie; `nil` when it lies off every screen.
    public static func screen(holdingMostOf window: CGRect, among screens: [Screen]) -> Screen? {
        var best: (screen: Screen, area: CGFloat)?
        for screen in screens {
            let area = overlap(window, screen.frame)
            if area > 0, area > (best?.area ?? 0) { best = (screen, area) }
        }
        return best?.screen
    }

    /// The area two rectangles share, 0 when they do not meet.
    public static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let shared = lhs.intersection(rhs)
        return shared.isNull ? 0 : shared.width * shared.height
    }

    /// One entry of `CGWindowListCopyWindowInfo`, the fields that need no Screen Recording permission: the owner,
    /// the layer, the opacity and the bounds — in Quartz coordinates, origin at the top left of the primary screen.
    public struct WindowInfo: Sendable, Equatable {
        public var pid: Int32
        public var layer: Int
        public var alpha: Double
        public var bounds: CGRect

        public init(pid: Int32, layer: Int, alpha: Double = 1, bounds: CGRect) {
            self.pid = pid
            self.layer = layer
            self.alpha = alpha
            self.bounds = bounds
        }

        /// Reads one dictionary of the list; `nil` when a field is missing.
        public init?(_ entry: [String: Any]) {
            guard let pid = (entry["kCGWindowOwnerPID"] as? NSNumber)?.int32Value,
                  let layer = (entry["kCGWindowLayer"] as? NSNumber)?.intValue,
                  let bounds = entry["kCGWindowBounds"] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue, let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
            self.init(pid: pid, layer: layer, alpha: (entry["kCGWindowAlpha"] as? NSNumber)?.doubleValue ?? 1,
                      bounds: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    /// Below this size on either side a window is a helper (a 1 × 1 event sink, a status item's shadow), not one the
    /// user looks at.
    static let smallestWindowSide: CGFloat = 40

    /// The frontmost real window of `pid` in a front-to-back window list, in Quartz coordinates: the first one of
    /// layer 0 — the layer of document windows; panels, menus and the island sit above — that is visible and not tiny.
    public static func frontWindow(of pid: Int32, in windows: [WindowInfo]) -> CGRect? {
        windows.first {
            $0.pid == pid && $0.layer == 0 && $0.alpha > 0
                && $0.bounds.width >= smallestWindowSide && $0.bounds.height >= smallestWindowSide
        }?.bounds
    }

    /// Whether `window` fills `screen` whole — an app in full screen, menu bar and Dock gone. A window merely zoomed
    /// stops under the menu bar, so it does not count.
    public static func isFullScreen(_ window: CGRect, on screen: Screen) -> Bool {
        window.insetBy(dx: -1, dy: -1).contains(screen.frame)
    }

    /// The document windows of `pid` — layer 0, visible — in a window list: an app in full screen often puts a toolbar
    /// strip in front of the window that fills the screen, so full screen is read from all of them.
    public static func documentWindows(of pid: Int32, in windows: [WindowInfo]) -> [CGRect] {
        windows.filter { $0.pid == pid && $0.layer == 0 && $0.alpha > 0 }.map(\.bounds)
    }

    /// Whether the collapsed island steps aside on `screen`: the settings want it, an app in front fills that screen
    /// (`frontWindows`, in AppKit coordinates), and nothing calls for the user — no request waiting, no request being
    /// revealed, the island not open.
    public static func hidesForFullScreen(settings: IslandSettings, frontWindows: [CGRect], on screen: Screen,
                                          isOpen: Bool, hasRequests: Bool, revealing: AlertKind?) -> Bool {
        guard settings.hidesInFullScreen, !isOpen, !hasRequests else { return false }
        if let revealing, revealing != .finished, revealing != .failed { return false }
        return frontWindows.contains { isFullScreen($0, on: screen) }
    }

    /// A Quartz rectangle (origin at the top left of the primary screen, y down) in AppKit's global coordinates (origin
    /// at the bottom left of the primary screen, y up). `primaryHeight` is the height of the screen at the origin —
    /// `NSScreen.screens[0]`, not `NSScreen.main`, which is wherever the key window is.
    public static func appKitRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The menu bar's height assumed on a screen without a notch when it hides; the capsule is a little shorter.
    public static let pillHeight: CGFloat = 26

    /// The collapsed shape's band: the notch itself, or where the capsule hangs on a screen without one — the top of the
    /// screen, centred, as high as the menu bar.
    public static func band(on screen: Screen) -> CGRect {
        if let notch = screen.notch { return notch }
        let height = screen.menuBarHeight > 0 ? screen.menuBarHeight : pillHeight
        return CGRect(x: screen.frame.midX, y: screen.frame.maxY - height, width: 0, height: height)
    }

    /// The panel's frame for content of `size`, hung from the top of the screen and centred on the band, kept inside
    /// the screen. The panel is exactly the content: a larger transparent window would take the clicks meant for the
    /// menu bar and the windows under it.
    public static func frame(for size: CGSize, on screen: Screen) -> CGRect {
        let band = band(on: screen)
        let width = min(size.width, screen.frame.width)
        let x = min(max(band.midX - width / 2, screen.frame.minX), screen.frame.maxX - width)
        return CGRect(x: x, y: screen.frame.maxY - size.height, width: width, height: size.height)
    }
}

// MARK: How it looks

extension Island {
    /// How the island stands on screen.
    public enum Presentation: Sendable, Equatable {
        /// The capsule hanging from the top edge, or the two wings around a notch.
        case collapsed
        /// Open on the list, by the pointer or a click.
        case expanded
        /// Widened, unasked, on one reveal: a request until it is answered, a turn that ended for a few seconds.
        case alert(Alert)
    }

    /// What `presentation` becomes once the threads read `snapshot`: a request's reveal folds back as soon as that
    /// request is no longer waiting — answered from the island, from the terminal, anywhere. A turn's reveal ends on
    /// its own timer, and the open island only when the user leaves it.
    public static func settle(_ presentation: Presentation, snapshot: Snapshot) -> Presentation {
        guard case .alert(let alert) = presentation, alert.isRequest else { return presentation }
        let waiting = snapshot.requests.contains { row in
            row.id == alert.thread && (alert.requestID == nil || row.thread.request?.id == alert.requestID)
        }
        return waiting ? presentation : .collapsed
    }

    /// What a reveal does to `presentation`: the island the user opened stays open, a request still waiting is not
    /// pushed aside by a turn that ended, anything else widens on the new reveal.
    public static func present(_ alert: Alert, over presentation: Presentation) -> Presentation {
        switch presentation {
        case .expanded: return .expanded
        case .alert(let current) where current.isRequest && !alert.isRequest: return presentation
        default: return .alert(alert)
        }
    }

    /// The collapsed counter: `3 threads` on a capsule, the bare `3` in a wing beside a notch, where room is short and
    /// the dots on the other side say what is counted. Counts what the dots stand for (`Snapshot.shownCount`).
    public static func counter(_ snapshot: Snapshot, onNotch: Bool) -> String {
        let count = snapshot.shownCount
        if onNotch { return "\(count)" }
        return count == 1 ? "1 thread" : "\(count) threads"
    }

    /// What VoiceOver reads for the collapsed island: the count, then how many in each state, then the 5-hour limit.
    public static func accessibilitySummary(_ snapshot: Snapshot, fiveHour: Double?) -> String {
        let states = (snapshot.requests + snapshot.groups.flatMap(\.rows)).map(\.thread.state)
        var parts: [String] = []
        let running = states.filter { $0 == .running }.count
        let waiting = states.filter(\.needsAttention).count
        let done = states.filter { $0 == .done }.count
        let failed = states.filter { $0 == .failed }.count
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting for you") }
        if done > 0 { parts.append("\(done) finished") }
        if failed > 0 { parts.append("\(failed) failed") }
        var text = "Scope island, " + counter(snapshot, onNotch: false)
        if !parts.isEmpty { text += ": " + parts.joined(separator: ", ") }
        if let fiveHour { text += ". 5-hour limit \(RateLimitText.percent(fiveHour)) used" }
        return text
    }

    /// The tone of a limit's ring or bar: light while there is room, orange from 80 %, red once used up — the levels
    /// of `RateLimitLevel`, folded to what reads on black.
    public enum LimitTone: Sendable, Equatable {
        case normal
        case high
        case exhausted
    }

    public static func limitTone(_ percentage: Double) -> LimitTone {
        switch RateLimitLevel(percentage: percentage) {
        case .calm, .watch: .normal
        case .tight: .high
        case .exhausted: .exhausted
        }
    }

    /// A request's buttons left to right: Open, then Deny and a question's options, Allow last — the one that lets the
    /// agent act sits where the eye ends, never first under the pointer.
    public static func buttons(_ actions: [Action]) -> [Action] {
        func rank(_ action: Action) -> Int {
            switch action {
            case .open: 0
            case .deny: 1
            case .choose: 2
            case .allow: 3
            }
        }
        return actions.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Whether the command of `row` is drawn whole, wrapping as it must, rather than cut to a line: always when Allow
    /// is on offer — allowing what was cut off is allowing what was not read.
    public static func showsCommandWhole(_ row: Row) -> Bool { row.actions.contains(.allow) }

    // MARK: Geometry

    /// The collapsed capsule's height on a screen without a notch: 6 pt short of the menu bar (24 on a 30 pt bar), so
    /// it hangs from the top edge instead of sitting on the bar like a second one, and never under 20 pt, which the
    /// ring and the counter need. Around a notch, the notch's own height.
    public static func collapsedHeight(on screen: Screen) -> CGFloat {
        if let notch = screen.notch { return notch.height }
        let bar = screen.menuBarHeight > 0 ? screen.menuBarHeight : pillHeight
        return max(20, bar - 6)
    }

    /// Sizes the collapsed content is laid out with, shared by the view and `wingWidth`.
    public enum Metrics {
        public static let dot: CGFloat = 7
        public static let dotSpacing: CGFloat = 4
        public static let ring: CGFloat = 14
        /// Between items: the dots, the counter, the ring.
        public static let gap: CGFloat = 8
        /// Each side of the capsule's content, and of a wing's.
        public static let padding: CGFloat = 12
        /// A monospaced digit at the counter's 12 pt semibold, and the `+` before an overflow, rounded up.
        public static let digit: CGFloat = 7.5
        public static let collapsedRadius: CGFloat = 14
        public static let openRadius: CGFloat = 22
        public static let openWidth: CGFloat = 440
        public static let widenedWidth: CGFloat = 460
    }

    /// The width of the dots and their `+N`, as the collapsed content lays them out.
    public static func dotsWidth(_ snapshot: Snapshot) -> CGFloat {
        let count = CGFloat(snapshot.dots.count)
        var width = count * Metrics.dot + max(0, count - 1) * Metrics.dotSpacing
        if snapshot.overflow > 0 { width += Metrics.dotSpacing + CGFloat("+\(snapshot.overflow)".count) * Metrics.digit }
        return width
    }

    /// The width of each wing around a notch: the wider of its two contents — the dots on the left, the counter and the
    /// ring on the right — plus padding, the same both sides so the shape stays centred on the notch.
    public static func wingWidth(_ snapshot: Snapshot, hasRing: Bool) -> CGFloat {
        let left = dotsWidth(snapshot)
        var right = CGFloat(counter(snapshot, onNotch: true).count) * Metrics.digit
        if hasRing { right += Metrics.gap + Metrics.ring }
        return (max(left, right) + 2 * Metrics.padding).rounded(.up)
    }

    /// The two wings beside `notch`, `width` each: nothing ever drawn under the notch itself, where the camera is.
    public static func wings(around notch: CGRect, width: CGFloat) -> (left: CGRect, right: CGRect) {
        (CGRect(x: notch.minX - width, y: notch.minY, width: width, height: notch.height),
         CGRect(x: notch.maxX, y: notch.minY, width: width, height: notch.height))
    }

    // MARK: Colours

    /// The island's state colours, as sRGB hex, for its black ground. Every pair the eye must tell apart also differs
    /// in luminance, so the dots still read in greyscale and to a colour-blind eye — beside their shapes (`StateDot`).
    /// The running green is a shade darker than the system's (#30D158), which has the very luminance of the orange.
    public enum Tint {
        public static let running = 0x208F3E
        public static let waiting = 0xFF9F0A
        public static let done = 0x0A84FF
        public static let failed = 0xFF453A
        /// A limit's track, and the request card's buttons.
        public static let track = 0x3A3A3C
        /// The open list's text: primary, secondary, tertiary.
        public static let primary = 0xF2F2F7
        public static let secondary = 0xAEAEB2
        public static let tertiary = 0x8E8E93
        /// Under a request in the open list: orange, very dark.
        public static let requestCard = 0x2C1E0A

        public static func of(_ state: ThreadState) -> Int? {
            switch state {
            case .running: running
            case .waiting: waiting
            case .done: done
            case .failed: failed
            case .idle, .exited: nil
            }
        }

        /// WCAG relative luminance of an sRGB hex colour.
        public static func luminance(_ hex: Int) -> Double {
            func channel(_ value: Int) -> Double {
                let c = Double(value) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
        }

        /// WCAG contrast ratio between two colours, 1 to 21.
        public static func contrast(_ lhs: Int, _ rhs: Int) -> Double {
            let a = luminance(lhs), b = luminance(rhs)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }
}
