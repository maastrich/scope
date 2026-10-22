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
    /// How the island stands on screen.
    enum Presentation: Equatable {
        case collapsed
        case expanded
        /// A reveal, for a few seconds: the collapsed shape grows to say what happened.
        case alert(Island.Alert)
    }

    private(set) var snapshot: Island.Snapshot = .empty
    var presentation: Presentation = .collapsed
    /// The five-hour window's share used, as Claude Code last reported it; `nil` when it has not, or it has reset.
    private(set) var fiveHourPercentage: Double?
    /// A one-line refusal after an answer that typed nothing, shown under the request until the next change.
    var refusal: (thread: ThreadID, text: String)?
    @ObservationIgnored fileprivate var inputs: [Island.ThreadInput] = []
    @ObservationIgnored fileprivate var memory = Island.AlertMemory()
    @ObservationIgnored fileprivate var alertEnds: Task<Void, Never>?
    @ObservationIgnored fileprivate var clock: Task<Void, Never>?
    @ObservationIgnored fileprivate var started = false
    @ObservationIgnored let quiet = IslandQuiet()

    fileprivate func publish(_ snapshot: Island.Snapshot, fiveHour: Double?) {
        if snapshot != self.snapshot { self.snapshot = snapshot }
        if fiveHour != fiveHourPercentage { fiveHourPercentage = fiveHour }
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
    /// writes one word to `$SCOPE_HOME/island-command` instead — `expanded`, `collapsed`, `allow`, `deny` (the first
    /// request, through the same path as the buttons) — read twice a second, then removed.
    private func startIslandDebugCommands() {
        let file = env.home.appendingPathComponent("island-command")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let word = try? String(contentsOf: file, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: file)
                switch word.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "expanded": self.island.presentation = .expanded
                case "collapsed": self.island.presentation = .collapsed
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
        threads.forEach { $0.settleOutlivedTurn() }
        island.quiet.refreshFocus()
        applyIsland(readIsland())
    }

    private struct IslandReading {
        var inputs: [Island.ThreadInput]
        var fiveHour: Double?
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
        let fiveHour = tokenUsage.currentLimits(now: now)?.current(now: now).first { $0.id == "five_hour" }?.usedPercentage
        return IslandReading(inputs: inputs, fiveHour: fiveHour, settings: config.preferences.island,
                             enabled: islandEnabled, now: now)
    }

    /// Publishes the snapshot and plays what changed since the last reading.
    private func applyIsland(_ reading: IslandReading) {
        island.publish(Island.snapshot(reading.inputs, now: reading.now), fiveHour: reading.fiveHour)
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
        if let alert = alerts.last { play(alert, sound: reading.settings.playsSound) }
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
        let background = session.runningSubagents(now: now) > 0 || !session.claude.background.running(at: now).isEmpty
        let task = task(of: session)
        return Island.ThreadInput(
            id: session.id, scopeID: session.record.scopeID, scopeName: scope(session.record.scopeID)?.name ?? "Scope",
            taskID: task?.id.rawValue, taskName: task?.name, title: session.title, state: state,
            activity: state.isUnreadResult ? (session.activityHeadline?.reply ?? session.activityHeadline?.text)
                : session.activityHeadline?.text, since: since, lastEventAt: heard, hasBackgroundWork: background,
            request: request, isForeground: session.id == foreground, turn: session.turnRevision)
    }

    /// A reveal: the collapsed island grows for a moment, unless the user has it open already.
    private func play(_ alert: Island.Alert, sound: Bool) {
        if sound { IslandSound.play(alert.kind) }
        guard island.presentation != .expanded else { return }
        island.presentation = .alert(alert)
        island.alertEnds?.cancel()
        island.alertEnds = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.islandAlertDuration * Self.islandAlertStretch)
            guard !Task.isCancelled, let self, case .alert(let shown) = self.island.presentation, shown == alert else { return }
            self.island.presentation = .collapsed
        }
    }

    // MARK: Gestures

    /// A click on a row: Scope comes up on that thread, its terminal with the keyboard.
    func openFromIsland(_ thread: ThreadID) {
        Usage.click("island.open", label: "Island ▸ Open thread")
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
