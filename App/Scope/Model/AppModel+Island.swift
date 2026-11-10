import AppKit
import Intents
import ScopeAdapters
import ScopeControl
import ScopeCore

/// What the island under the notch shows and does (spec §7). The model works out the `Island.Snapshot` and the
/// reveals from the threads; `IslandController` draws them. The answers it gives go through the paths the
/// notification, the Inbox and the request card already use (`answerPendingRequest`, `reveal(thread:)`).
@MainActor
@Observable
final class IslandModel {
    typealias Presentation = Island.Presentation

    private(set) var snapshot: Island.Snapshot = .empty
    var presentation: Presentation = .collapsed
    /// The last request revealed: closing the list goes back to it while it still waits (`Island.respond`).
    @ObservationIgnored var heldRequest: Island.Alert?
    /// Reveals waiting for the one on screen to go (`Island.AlertQueue`).
    @ObservationIgnored var queue = Island.AlertQueue()
    /// How many wait, for the notice's "2 more".
    private(set) var queuedCount = 0
    /// When the notice on screen folds away; `nil` while the pointer holds it, or for a request.
    struct NoticeClock: Equatable {
        var ends: Date
    }
    var noticeClock: NoticeClock?
    /// The pointer is on the island (set by `IslandController` at once, unlike the delayed gestures).
    @ObservationIgnored var hovering = false

    func syncQueueCount() {
        if queue.count != queuedCount { queuedCount = queue.count }
    }
    /// The five-hour and weekly windows, as Claude Code last reported them; `nil` when it has not, or once reset.
    private(set) var fiveHour: RateLimits.Window?
    private(set) var sevenDay: RateLimits.Window?
    var fiveHourPercentage: Double? { fiveHour?.usedPercentage }
    /// A one-line refusal after an answer that typed nothing, shown under the request until the next change.
    var refusal: (thread: ThreadID, text: String)?
    @ObservationIgnored fileprivate var inputs: [Island.ThreadInput] = []
    @ObservationIgnored fileprivate var memory = Island.AlertMemory()
    @ObservationIgnored fileprivate var alertEnds: Task<Void, Never>?
    @ObservationIgnored fileprivate var clock: Task<Void, Never>?
    @ObservationIgnored fileprivate var started = false
    @ObservationIgnored let quiet = IslandQuiet()

    fileprivate func publish(_ snapshot: Island.Snapshot, fiveHour: RateLimits.Window?, sevenDay: RateLimits.Window?) {
        if snapshot != self.snapshot { self.snapshot = snapshot }
        if fiveHour != self.fiveHour { self.fiveHour = fiveHour }
        if sevenDay != self.sevenDay { self.sevenDay = sevenDay }
    }

    var refusalText: String? { refusal?.text }
}

extension AppModel {
    /// How long a reveal stays before the island folds back.
    static let islandAlertDuration: Duration = .seconds(5)
    #if DEBUG
    /// `SCOPE_ISLAND_ALERT_STRETCH=12` keeps a reveal up a minute, long enough to screenshot it.
    static let islandAlertStretch = Int(ProcessInfo.processInfo.environment["SCOPE_ISLAND_ALERT_STRETCH"] ?? "") ?? 1
    #else
    static let islandAlertStretch = 1
    #endif

    var islandEnabled: Bool { config.preferences.island.isEnabled(automatic: !BuildFlavor.isDebug) }

    /// After bootstrap: follows the threads and the settings for as long as the app runs.
    func startIsland() {
        guard !island.started else { return }
        island.started = true
        trackIsland()
        // Durations tick in the views; this only catches a running thread going quiet and a window resetting.
        island.clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.refreshIsland()
            }
        }
        #if DEBUG
        startIslandDebugCommands()
        #endif
    }

    #if DEBUG
    /// A throwaway instance driven from a terminal has no pointer on the island and no Accessibility to click it: it
    /// writes one word to `$SCOPE_HOME/island-command` instead — `expanded`, `collapsed`, `widen` (the first request,
    /// as its reveal would), `allow`, `deny` (the first request, through the same path as the buttons), `peek` /
    /// `unpeek` (the pointer on it or not, without the delayed opening), `finished` / `compact` (a turn's notice for the
    /// first thread listed, as a card or in the band) — read twice a second, then removed.
    private func startIslandDebugCommands() {
        let file = env.home.appendingPathComponent("island-command")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let word = try? String(contentsOf: file, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: file)
                let command = word.trimmingCharacters(in: .whitespacesAndNewlines)
                switch command {
                case "expanded": self.island.presentation = .expanded
                case "collapsed": self.island.presentation = .collapsed
                case "peek": IslandController.shared.debugHover(true)
                case "unpeek": IslandController.shared.debugHover(false)
                case "finished", "compact":
                    guard let row = self.island.snapshot.groups.flatMap(\.rows).first else { return }
                    self.play(Island.Alert(key: "debug-\(Date.now.timeIntervalSince1970)", kind: .finished, thread: row.id,
                                           title: row.thread.title, line: row.line, style: command == "compact" ? .compact : .card))
                case "widen":
                    guard let row = self.island.snapshot.requests.first else { return }
                    let alert = Island.Alert(
                        key: "debug", kind: row.thread.request?.kind == .plan ? .plan : .permission, thread: row.id,
                        title: row.thread.title, line: row.line, requestID: row.thread.request?.id)
                    self.island.heldRequest = alert
                    self.island.presentation = .alert(alert)
                case let answer where answer == "allow" || answer == "deny":
                    guard let row = self.island.snapshot.requests.first else { return }
                    self.answerFromIsland(row.id, action: answer == "allow" ? .allow : .deny)
                default: break
                }
            }
        }
    }
    #endif

    /// Re-reads on every change of what the island shows, and acts on it outside the tracking: what it writes must not
    /// count as a change of what it read.
    private func trackIsland() {
        let reading = withObservationTracking {
            readIsland()
        } onChange: {
            Task { @MainActor [weak self] in self?.trackIsland() }
        }
        applyIsland(reading)
    }

    func refreshIsland() {
        // A turn whose end the hooks lost but the agent's last answer settled is over (`ThreadWait`).
        threads.forEach { $0.settleOutlivedTurn(noticedBy: "island") }
        island.quiet.refreshFocus()
        applyIsland(readIsland())
    }

    private struct IslandReading {
        var inputs: [Island.ThreadInput]
        var fiveHour: RateLimits.Window?
        var sevenDay: RateLimits.Window?
        var settings: IslandSettings
        var enabled: Bool
        var now: Date
    }

    /// Every thread whose driver reports its turns, as the island takes it.
    private func readIsland(now: Date = .now) -> IslandReading {
        let foreground = NSApplication.shared.isActive ? selectedThreadID : nil
        let inputs: [Island.ThreadInput] = threads.compactMap { session in
            guard session.deliversEvents, session.isAlive else { return nil }
            return islandInput(session, foreground: foreground, now: now)
        }
        let windows = tokenUsage.currentLimits(now: now)?.current(now: now) ?? []
        return IslandReading(inputs: inputs, fiveHour: windows.first { $0.id == "five_hour" },
                             sevenDay: windows.first { $0.id == "seven_day" }, settings: config.preferences.island,
                             enabled: islandEnabled, now: now)
    }

    /// Publishes the snapshot and plays what changed since the last reading.
    private func applyIsland(_ reading: IslandReading) {
        let snapshot = Island.snapshot(reading.inputs, now: reading.now)
        island.publish(snapshot, fiveHour: reading.fiveHour, sevenDay: reading.sevenDay)
        let settled = Island.settle(island.presentation, snapshot: snapshot)
        if settled != island.presentation {
            // A request answered anywhere: the next reveal waiting, if any, takes its place.
            island.presentation = settled
            if settled == .collapsed { endNotice() }
        }
        island.quiet.refreshActivity()
        let alerts = Island.alerts(from: island.inputs, to: reading.inputs, settings: reading.settings,
                                   quiet: island.quiet.current, memory: &island.memory)
        island.inputs = reading.inputs
        if let refusal = island.refusal,
           !reading.inputs.contains(where: { $0.id == refusal.thread && $0.state.needsAttention }) {
            island.refusal = nil
        }
        guard reading.enabled else {
            IslandController.shared.hide()
            return
        }
        // Only once the island shows: asking for the Focus status is a system prompt nobody with it off should see.
        island.quiet.start()
        IslandController.shared.show(model: self)
        // Every reveal, one after the other; one sound for the burst, the most urgent's.
        if reading.settings.playsSound,
           let loudest = alerts.first(where: \.isRequest) ?? alerts.first(where: { $0.kind == .failed }) ?? alerts.first {
            IslandSound.play(loudest.kind)
        }
        alerts.forEach(play)
    }

    private func islandInput(_ session: ThreadSession, foreground: ThreadID?, now: Date) -> Island.ThreadInput {
        let state = session.displayState
        let request = state.needsAttention ? pendingRequest(of: session.id) : nil
        let activity = session.activity
        let since: Date? = switch state {
        case .running: activity.turnStartedAt
        case .waiting: request?.askedAt ?? activity.turns.last?.endedAt
        default: activity.turns.last?.endedAt
        }
        let heard = [activity.lastTool?.at, activity.turnStartedAt, activity.saying?.at, activity.lastReply?.at]
            .compactMap { $0 }.max()
        let agents = session.runningSubagents(now: now)
        let background = agents > 0 || !session.claude.background.running(at: now).isEmpty
        // The tool of the turn in progress only: the last one of a turn already over says nothing of now.
        let tool = activity.lastTool.flatMap { tool in
            activity.turnStartedAt.map { tool.at >= $0 } == true ? tool.name : nil
        }
        let task = task(of: session)
        return Island.ThreadInput(
            id: session.id, scopeID: session.record.scopeID, scopeName: scope(session.record.scopeID)?.name ?? "Scope",
            taskID: task?.id.rawValue, taskName: task?.name, title: session.title, state: state,
            activity: state.isUnreadResult ? (session.activityHeadline?.reply ?? session.activityHeadline?.text)
                : session.activityHeadline?.text, since: since, lastEventAt: heard, hasBackgroundWork: background,
            request: request, isForeground: session.id == foreground, turn: session.turnRevision,
            plan: activity.plan, turnLength: activity.turns.last.flatMap { turn in turn.startedAt.map { turn.endedAt.timeIntervalSince($0) } },
            turnTools: activity.turns.last?.tools, tool: tool, agents: agents)
    }

    /// A reveal: it plays now, waits for the one on screen, or — the list open, which already shows it — nothing
    /// (`Island.arrival`). A request stays until it is answered (`Island.settle`); a turn for `noticeDuration`, held
    /// while the pointer is on it.
    private func play(_ alert: Island.Alert) {
        if alert.isRequest { island.heldRequest = alert }
        switch Island.arrival(of: alert, over: island.presentation, hovering: island.hovering) {
        case .drop:
            return
        case .queue:
            // A request pushing a turn's notice aside: the notice comes back after it.
            island.queue.push(alert)
            island.syncQueueCount()
        case .show:
            if case .alert(let current) = island.presentation, !current.isRequest, alert.isRequest {
                island.queue.push(current)
                island.syncQueueCount()
            }
            show(alert)
        }
    }

    private func show(_ alert: Island.Alert) {
        island.presentation = .alert(alert)
        startNoticeClock(for: alert, after: nil)
    }

    /// Runs the time of the notice on screen: its own duration, or `linger` once the pointer left it.
    private func startNoticeClock(for alert: Island.Alert, after linger: TimeInterval?) {
        island.alertEnds?.cancel()
        guard let duration = linger ?? Island.noticeDuration(alert) else {
            island.noticeClock = nil
            return
        }
        let seconds = duration * Double(Self.islandAlertStretch)
        island.noticeClock = .init(ends: .now.addingTimeInterval(seconds))
        island.alertEnds = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, case .alert(let shown) = self.island.presentation, shown.key == alert.key,
                  !self.island.hovering else { return }
            self.endNotice()
        }
    }

    /// The notice on screen is over: the next one waiting, if it still says something true, else the band.
    func endNotice() {
        island.alertEnds?.cancel()
        island.noticeClock = nil
        let next = island.queue.next(in: island.snapshot)
        island.syncQueueCount()
        if let next {
            show(next)
        } else if case .alert = island.presentation {
            island.presentation = .collapsed
        }
    }

    // MARK: Gestures

    /// A pointer or a click on the island, through `Island.respond`.
    func islandGesture(_ gesture: Island.Gesture) {
        let before = island.presentation
        let next = Island.respond(to: gesture, presentation: before, held: island.heldRequest, snapshot: island.snapshot)
        if next != before { island.presentation = next }
        // A turn's notice holds while the pointer is on it and lingers a moment once it left; a compact one opened on
        // its card starts its card's time.
        guard case .alert(let alert) = next, !alert.isRequest else { return }
        switch gesture {
        case .pointerIn:
            island.alertEnds?.cancel()
            island.noticeClock = nil
        case .pointerOut:
            startNoticeClock(for: alert, after: Island.lingerAfterHover)
        case .toggle, .clickOutside:
            break
        }
    }

    /// A click on a row: Scope comes up on that thread, its terminal with the keyboard.
    func openFromIsland(_ thread: ThreadID) {
        Usage.click("island.open", label: "Island ▸ Open thread")
        // Taken to the thread: its request is in front of the user now, the island need not come back to it.
        if island.heldRequest?.thread == thread { island.heldRequest = nil }
        island.queue.remove(thread: thread)
        island.syncQueueCount()
        island.alertEnds?.cancel()
        island.noticeClock = nil
        island.presentation = .collapsed
        reveal(thread: thread, showDelta: false)
        AppDelegate.refocusTerminal()
    }

    /// Allow, Deny or an option, typed only if the terminal shows that very dialog (`answerPendingRequest`).
    func answerFromIsland(_ thread: ThreadID, action: Island.Action) {
        // Only what the row offers: Allow for a command the island did not show whole is never typed, whoever asks.
        guard let request = pendingRequest(of: thread),
              let row = island.snapshot.requests.first(where: { $0.id == thread }), row.actions.contains(action)
        else { return }
        let answer: ClaudeDialogAnswer
        switch action {
        case .allow: answer = .allow
        case .deny: answer = .deny
        case .choose(let index, _): answer = .choose([[index]])
        case .open:
            openFromIsland(thread)
            return
        }
        Usage.click("island.answer", label: "Island ▸ Answer")
        if case .failure(let refusal) = answerPendingRequest(thread, requestID: request.id, with: answer) {
            island.refusal = (thread, refusal.description)
        }
    }
}

/// Whether the Mac wants quiet: a Focus is on (when Scope may read it), or the screen is locked or asleep.
@MainActor
final class IslandQuiet {
    private(set) var current = Island.Quiet()
    private var observers: [NSObjectProtocol] = []

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.current.screenLocked = true }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.current.screenLocked = false }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.current.screenLocked = true }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.current.screenLocked = false }
        })
        // Focus has no notification Scope can observe: it is read each time it matters, once Scope may.
        if INFocusStatusCenter.default.authorizationStatus == .notDetermined {
            INFocusStatusCenter.default.requestAuthorization { _ in }
        }
        refreshFocus()
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
    }

    /// Whether a key, a click or the pointer moved lately, in any app. The HID system's idle time needs no permission —
    /// unlike reading the events themselves.
    func refreshActivity() {
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        current.userActive = idle < Island.Quiet.recentInput
    }

    /// `isFocused` is `nil` when Scope may not know; then it is taken as no Focus.
    func refreshFocus() {
        let center = INFocusStatusCenter.default
        current.focus = center.authorizationStatus == .authorized && center.focusStatus.isFocused == true
    }

    var focusAuthorization: INFocusStatusAuthorizationStatus { INFocusStatusCenter.default.authorizationStatus }
}

/// The sounds of the reveals: system sounds, so nothing is shipped and they sound like the Mac.
enum IslandSound {
    static func play(_ kind: Island.AlertKind) {
        let name = switch kind {
        case .finished: "Tink"
        case .failed: "Basso"
        case .question, .permission, .plan: "Glass"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
