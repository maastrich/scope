import AppKit
import Foundation
import ScopeAdapters
import ScopeAssist
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// The acting triggers' state beyond `AppModel`: the ledger, the network, the relaunches waiting for it, and which
/// trigger opened each thread's turn. One for the app.
@MainActor
final class ActingEngine {
    static let shared = ActingEngine()

    /// A failed turn waiting for the network, the usage reset or a backoff.
    struct PendingRelaunch {
        var trigger: ActingTrigger
        var failure: TurnFailure
        /// What the error said, quoted in the message.
        var words: String?
        var failedAt: Date
        /// The process died with the turn (sleep, a kill): the session is restarted rather than typed into.
        var processDied: Bool
    }

    /// A stuck verdict waiting out its grace, so "Not stuck" can still cancel it.
    struct PendingStuck {
        var key: String
        var reason: String
        var since: Date
    }

    var ledger = ActingLedger()
    var store: ActingLedgerStore?
    let network = NetworkWatch()
    var relaunches: [ThreadID: PendingRelaunch] = [:]
    /// Relaunches in a row that failed again, per thread: the backoff's step. A turn that ends normally resets it.
    var attempts: [ThreadID: Int] = [:]
    var stuck: [ThreadID: PendingStuck] = [:]
    /// The trigger whose message opened a thread's turn, and when it was typed.
    var openedBy: [ThreadID: (trigger: ActingTrigger, at: Date)] = [:]
    /// Holds already journaled, by trigger, thread, key and cause: a held proposal comes back at every refresh.
    var journaledHolds: Set<String> = []
    var sleptAt: Date?
    /// When each pull request head was first seen failing, by `url@sha`.
    var failingSince: [String: Date] = [:]
    /// The last review probe of each pull request, by URL.
    var reviewProbes: [String: AppModel.ReviewProbe] = [:]
    var tick: Task<Void, Never>?
    var observers: [NSObjectProtocol] = []
    var started = false
}

/// Triggers that act (spec §4.10, `ActingTriggers`): this gathers their facts from the threads, the network, the
/// usage limits and the pull requests, runs every proposal through the gate, and carries out what passes — a message
/// typed between turns, a session restarted, a turn interrupted. Each act is journaled (`JournalEvent.Kind.trigger`)
/// and shows on the thread's activity line; past a cap, or with no thread able to act, the user is told instead.
extension AppModel {
    var acting: ActingEngine { ActingEngine.shared }

    /// How often waiting relaunches and stuck verdicts are looked at.
    static let actingTickInterval: Duration = .seconds(5)
    /// A stuck verdict stands this long before the turn is interrupted: time for the user to say "Not stuck".
    static let stuckGrace: TimeInterval = 60

    func startActingTriggers() {
        let engine = acting
        guard !engine.started else { return }
        engine.started = true
        let store = ActingLedgerStore(home: env.home)
        engine.store = store
        Task { [weak self] in
            let ledger = await store.load()
            self?.acting.ledger = ledger
        }
        engine.network.start(home: env.home) { [weak self] in self?.checkRelaunches() }
        let center = NSWorkspace.shared.notificationCenter
        engine.observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActingEngine.shared.sleptAt = .now }
        })
        engine.observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.macDidWake() }
        })
        engine.tick = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.actingTickInterval)
                guard let self else { return }
                self.checkRelaunches()
                self.checkStuck()
            }
        }
    }

    func preference(_ trigger: ActingTrigger) -> ActingTriggerPreference {
        config.preferences.actingTriggers[trigger]
    }

    // MARK: Hook events

    /// Runs before the notification decision: a failed turn Scope will relaunch does not ring as "stopped on an error".
    func actingSaw(_ event: AdapterEvent, session: ThreadSession) {
        let engine = acting
        let id = session.id
        switch event.kind {
        case .turnStarted:
            // A tool report is the same turn going on; a prompt is a new one.
            guard event.payload[HookEvent.toolKey].map(\.isEmpty) ?? true else { return }
            engine.relaunches[id] = nil
            session.setActingNote(nil)
            // Scope's message opened this turn only if it went out moments ago and the user typed nothing since.
            if let opened = engine.openedBy[id], Date.now.timeIntervalSince(opened.at) > 30
                || (session.lastUserInputAt.map { $0 > opened.at } ?? false) {
                engine.openedBy[id] = nil
            }
        case .turnEnded:
            engine.relaunches[id] = nil
            engine.attempts[id] = nil
            engine.stuck[id] = nil
        case .turnFailed:
            noteFailedTurn(event, session: session)
        default:
            break
        }
    }

    /// Whether the failed turn of `id` is waiting for a relaunch: its notification is not worth ringing.
    func actingWillRelaunch(_ id: ThreadID) -> Bool { acting.relaunches[id] != nil }

    private func noteFailedTurn(_ event: AdapterEvent, session: ThreadSession) {
        let engine = acting
        let words = HookEvent.failureWords(event)
        let windows = (tokenUsage.limits?.windows ?? []).map { TurnFailure.Window(usedPercentage: $0.usedPercentage, resetsAt: $0.resetsAt) }
        let failure = TurnFailure.classify(error: event.payload[HookEvent.errorKey], message: words, windows: windows)
        let trigger: ActingTrigger
        switch failure {
        case .network:
            // A failure while the Mac slept, or Claude Code saying so, is the wake trigger's: same rules, its own cap.
            let duringSleep = engine.sleptAt.map { event.receivedAt.timeIntervalSince($0) > -60 } ?? false
            trigger = (failure == .network("asleep") || duringSleep) ? .wake : .connectionLost
        case .usageLimit, .throttled:
            trigger = .usageLimit
        case .other:
            journalTrigger(.connectionLost, session: session, outcome: "skipped", cause: failure.cause)
            return
        }
        guard preference(trigger).enabled else {
            journalTrigger(trigger, session: session, outcome: "skipped", cause: "off")
            return
        }
        engine.relaunches[session.id] = .init(trigger: trigger, failure: failure, words: words, failedAt: event.receivedAt,
                                              processDied: false)
        journalTrigger(trigger, session: session, outcome: "waiting", cause: failure.cause)
        session.setActingNote(waitingNote(engine.relaunches[session.id]!))
        Log.app.notice("thread \(session.id.rawValue, privacy: .public): turn failed (\(failure.cause, privacy: .public)), relaunch pending")
        checkRelaunches()
    }

    private func waitingNote(_ pending: ActingEngine.PendingRelaunch) -> String {
        switch pending.failure {
        case .usageLimit(let resetsAt?):
            "Usage limit — Scope resumes it at \(resetsAt.formatted(date: .omitted, time: .shortened))"
        case .usageLimit(nil), .throttled:
            "Usage limit — Scope retries it later"
        default:
            acting.network.state.online ? "Network error — Scope resumes it shortly" : "Offline — Scope resumes it when the network is back"
        }
    }

    // MARK: Relaunches

    /// Every waiting relaunch whose moment came: the network back and settled, the usage window reset, the backoff
    /// over. Called on every tick and on every change of the network path.
    func checkRelaunches(now: Date = .now) {
        let engine = acting
        for (id, pending) in engine.relaunches {
            guard let session = session(id) else {
                engine.relaunches[id] = nil
                continue
            }
            let attempt = engine.attempts[id] ?? 0
            let due: Date? = switch pending.failure {
            case .network:
                RelaunchTiming.networkRelaunch(failedAt: pending.failedAt, attempt: attempt, network: engine.network.state)
            case .usageLimit(let resetsAt):
                RelaunchTiming.limitRelaunch(failedAt: pending.failedAt, resetsAt: resetsAt, throttled: false, attempt: attempt)
            case .throttled:
                RelaunchTiming.limitRelaunch(failedAt: pending.failedAt, resetsAt: nil, throttled: true, attempt: attempt)
            case .other:
                nil
            }
            // A failed turn may wait on the network as well: nothing goes out offline.
            guard let due, now >= due, engine.network.state.online else {
                session.setActingNote(waitingNote(pending))
                continue
            }
            let message: String = switch pending.trigger {
            case .wake: ActingPrompts.afterWake(error: pending.words, restarted: !session.isAlive)
            case .usageLimit:
                if case .usageLimit(let resetsAt) = pending.failure {
                    ActingPrompts.limitReset(resetsAt: resetsAt, throttled: false)
                } else {
                    ActingPrompts.limitReset(resetsAt: nil, throttled: true)
                }
            default: ActingPrompts.connectionBack(error: pending.words)
            }
            let action: ActingTriggers.Action = session.isAlive ? .send(message) : .restart(note: message)
            let proposal = ActingTriggers.Proposal(trigger: pending.trigger, thread: id,
                                                   key: "fail@\(Int(pending.failedAt.timeIntervalSince1970))",
                                                   action: action, cause: pending.failure.cause)
            switch fire(proposal, now: now) {
            case .act:
                engine.relaunches[id] = nil
                engine.attempts[id] = attempt + 1
                let why = switch pending.trigger {
                case .wake: "after sleep"
                case .usageLimit: "limit reset"
                default: "connection back"
                }
                session.setActingNote("Resumed by Scope — \(why)")
            case .hold:
                continue
            case .skip, .capped:
                engine.relaunches[id] = nil
                session.setActingNote(nil)
            }
        }
    }

    // MARK: Wake

    /// The Mac woke up: every agent thread whose process died while it slept with a turn open is restarted on its
    /// conversation, once the network is back (`checkRelaunches`). Failed turns are already waiting from their hook.
    func macDidWake(now: Date = .now) {
        let engine = acting
        let slept = engine.sleptAt ?? now.addingTimeInterval(-60)
        Log.app.notice("woke after \(Int(now.timeIntervalSince(slept)), privacy: .public) s")
        for session in threads where session.deliversEvents && !session.isAlive {
            guard engine.relaunches[session.id] == nil, let exit = session.record.lastExit, exit.at >= slept.addingTimeInterval(-60),
                  session.activity.turns.last?.outcome == .exited || session.activity.inTurn else { continue }
            guard preference(.wake).enabled else {
                journalTrigger(.wake, session: session, outcome: "skipped", cause: "off")
                continue
            }
            engine.relaunches[session.id] = .init(trigger: .wake, failure: .network("asleep"), words: nil, failedAt: exit.at,
                                                  processDied: true)
            journalTrigger(.wake, session: session, outcome: "waiting", cause: "process-died")
        }
        // The sleep is over: failures from now on are the network's again.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            if ActingEngine.shared.sleptAt == slept { ActingEngine.shared.sleptAt = nil }
            self?.checkRelaunches()
        }
        checkRelaunches(now: now)
    }

    // MARK: Stuck

    /// The assistant read the running turn as stuck: after `stuckGrace`, unless the user said "Not stuck" or the turn
    /// moved on, it is interrupted and asked to change approach.
    func noteStuck(_ session: ThreadSession, reason: String) {
        guard preference(.stuck).enabled, let started = session.activity.turnStartedAt else { return }
        let key = "turn@\(Int(started.timeIntervalSince1970))"
        guard acting.stuck[session.id]?.key != key else { return }
        acting.stuck[session.id] = .init(key: key, reason: reason, since: .now)
        journalTrigger(.stuck, session: session, outcome: "waiting", cause: "grace")
    }

    func cancelStuck(_ id: ThreadID) {
        guard let session = session(id), acting.stuck.removeValue(forKey: id) != nil else { return }
        journalTrigger(.stuck, session: session, outcome: "skipped", cause: "not-stuck")
    }

    func checkStuck(now: Date = .now) {
        for (id, pending) in acting.stuck where now.timeIntervalSince(pending.since) >= Self.stuckGrace {
            guard let session = session(id), session.isAlive, session.displayState == .running,
                  session.assistNote?.isStuck == true,
                  session.activity.turnStartedAt.map({ "turn@\(Int($0.timeIntervalSince1970))" }) == pending.key else {
                acting.stuck[id] = nil
                continue
            }
            let proposal = ActingTriggers.Proposal(trigger: .stuck, thread: id, key: pending.key,
                                                   action: .interrupt(then: ActingPrompts.stuck(reason: pending.reason)),
                                                   cause: "stuck")
            switch fire(proposal, now: now) {
            case .hold: continue
            case .act, .skip, .capped: acting.stuck[id] = nil
            }
        }
    }

    // MARK: Pull requests

    /// The thread of `task` that is told about its pull request: the first live one that reports its turns.
    func actingThread(in taskID: TaskID) -> ThreadSession? {
        threads(in: taskID).first { $0.isAlive && $0.deliversEvents }
    }

    /// A pull request trigger for `task`: through the gate on its thread, or — with no thread able to act — one
    /// notification per key to the user.
    @discardableResult
    func fire(_ trigger: ActingTrigger, in task: TaskState, key: String, message: String, cause: String,
              notice: String) -> ActingTriggers.Verdict {
        guard preference(trigger).enabled else { return .skip("off") }
        guard let session = actingThread(in: task.id) else {
            notifyNoThread(trigger, task: task, key: key, notice: notice)
            return .skip("no-thread")
        }
        let proposal = ActingTriggers.Proposal(trigger: trigger, thread: session.id, key: key, action: .send(message), cause: cause)
        let verdict = fire(proposal)
        if case .act = verdict { session.setActingNote(nil) }
        return verdict
    }

    // MARK: The gate

    /// The gate's facts for a thread, from its session.
    func actingFacts(_ session: ThreadSession) -> ActingTriggers.ThreadFacts {
        let waiting = if case .waiting = session.displayState { true } else { false }
        // A message already queued for it, a restart or a resume under way: the thread is spoken for.
        let spokenFor = !(pendingDeliveries[session.id] ?? []).isEmpty || restartingThreads.contains(session.id)
            || session.resumingAfterRestart
        return ActingTriggers.ThreadFacts(
            id: session.id, alive: session.isAlive, canRestart: restartUnavailable(session) == nil,
            inTurn: session.isAlive && (session.activity.inTurn || session.isWorking || spokenFor),
            waitingForUser: session.isAlive && waiting, lastUserInputAt: session.lastUserInputAt,
            turnOpenedBy: acting.openedBy[session.id]?.trigger)
    }

    /// One proposal through the gate, and what passes carried out. Journaled whatever the verdict (a hold once per
    /// cause); a cap reached tells the user once per hour.
    @discardableResult
    func fire(_ proposal: ActingTriggers.Proposal, now: Date = .now) -> ActingTriggers.Verdict {
        let engine = acting
        let session = session(proposal.thread)
        let verdict = ActingTriggers.decide(proposal, thread: session.map(actingFacts), preference: preference(proposal.trigger),
                                            ledger: engine.ledger, now: now)
        guard let session else { return verdict }
        switch verdict {
        case .act:
            engine.ledger.recordAct(proposal.trigger, on: proposal.thread, key: proposal.key, at: now)
            saveActingLedger()
            perform(proposal, on: session)
            journalTrigger(proposal.trigger, session: session, outcome: proposal.action.outcome, cause: proposal.cause)
            Log.app.notice("trigger \(proposal.trigger.rawValue, privacy: .public) on \(proposal.thread.rawValue, privacy: .public): \(proposal.action.outcome, privacy: .public) (\(proposal.key, privacy: .public))")
        case .hold(let cause):
            let mark = "\(proposal.trigger.rawValue)|\(proposal.thread.rawValue)|\(proposal.key)|\(cause)"
            if engine.journaledHolds.insert(mark).inserted {
                journalTrigger(proposal.trigger, session: session, outcome: "held", cause: cause)
            }
        case .skip(let cause):
            // `done` comes back at every refresh of a pull request already handled: nothing new to say.
            if cause != "done" { journalTrigger(proposal.trigger, session: session, outcome: "skipped", cause: cause) }
        case .capped:
            notifyCapped(proposal.trigger, session: session, now: now)
        }
        return verdict
    }

    private func perform(_ proposal: ActingTriggers.Proposal, on session: ThreadSession) {
        let id = session.id
        acting.openedBy[id] = (proposal.trigger, .now)
        switch proposal.action {
        case .send(let text):
            session.submit(text)
        case .restart(let note):
            Task { [weak self] in
                guard let self else { return }
                let outcome = await self.restartSession(id, source: .trigger, note: note)
                if let reason = outcome.failure, let session = self.session(id) {
                    self.journalTrigger(proposal.trigger, session: session, outcome: "failed", cause: "restart")
                    self.problems.warn("Scope could not restart a thread after \(proposal.trigger.title.lowercased())",
                                       detail: "“\(session.title)”: \(reason)", scope: session.record.scopeID)
                }
            }
        case .interrupt(let text):
            guard session.interruptForTrigger() else {
                session.submit(text)
                return
            }
            Task { [weak self] in
                // Claude Code takes a moment to close the turn and give the prompt back after Esc.
                try? await Task.sleep(for: .seconds(2))
                guard let session = self?.session(id), session.isAlive else { return }
                session.submit(text)
            }
        }
    }

    // MARK: Telling the user

    private func notifyCapped(_ trigger: ActingTrigger, session: ThreadSession, now: Date) {
        let key = ActingLedger.capKey(at: now)
        guard !acting.ledger.hasNotified(trigger, on: session.id, key: key) else { return }
        acting.ledger.recordNotice(trigger, on: session.id, key: key, at: now)
        saveActingLedger()
        journalTrigger(trigger, session: session, outcome: "capped", cause: "hourly-cap")
        let cap = preference(trigger).hourlyCap
        let body = "\(trigger.title): Scope acted \(cap) time\(cap == 1 ? "" : "s") on this thread in the last hour and stops here. Have a look."
        problems.warn("Scope stopped acting on a thread: \(trigger.title.lowercased())", detail: "“\(session.title)” — \(body)",
                      scope: session.record.scopeID)
        session.setActingNote("Scope stopped — \(trigger.title.lowercased()), \(cap)× this hour")
        post(trigger, about: session, body: body)
    }

    private func notifyNoThread(_ trigger: ActingTrigger, task: TaskState, key: String, notice: String) {
        // Keyed on the task: there is no thread to hang it on.
        let subject = "task:\(task.id.rawValue)"
        guard !acting.ledger.hasNotified(trigger, about: subject, key: key) else { return }
        acting.ledger.recordNotice(trigger, about: subject, key: key, at: .now)
        saveActingLedger()
        Journal.record(JournalEvent(kind: .trigger, name: trigger.rawValue, outcome: "notified", cause: "no-thread", task: task.id.rawValue))
        problems.warn("\(trigger.title) on a task with no agent to tell", detail: "\(task.name): \(notice)", scope: task.scopeID)
        if let session = threads(in: task.id).first { post(trigger, about: session, body: notice) }
    }

    private func post(_ trigger: ActingTrigger, about session: ThreadSession, body: String) {
        guard let scope = scope(session.record.scopeID) else { return }
        let parts = [session.profile.name, scope.name] + (task(of: session).map { [$0.name] } ?? [])
        let content = ThreadNotificationContent(title: parts.joined(separator: " · "), subtitle: trigger.title, body: body)
        notifier.post(content, threadID: session.id)
    }

    func journalTrigger(_ trigger: ActingTrigger, session: ThreadSession, outcome: String, cause: String?) {
        let count = acting.ledger.acts(trigger, on: session.id, since: Date.now.addingTimeInterval(-3600))
        Journal.record(JournalEvent(kind: .trigger, name: trigger.rawValue, outcome: outcome, cause: cause,
                                    task: session.record.taskID, thread: session.id.rawValue, count: count))
    }

    func saveActingLedger() {
        guard let store = acting.store else { return }
        let ledger = acting.ledger
        Task { await store.save(ledger) }
    }

    /// The thread is closed for good.
    func forgetActing(_ id: ThreadID) {
        let engine = acting
        engine.relaunches[id] = nil
        engine.attempts[id] = nil
        engine.stuck[id] = nil
        engine.openedBy[id] = nil
    }
}
