import AppKit
import Foundation
import Observation
import ScopeAdapters
import ScopeAssist
import ScopeControl
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// The assistant's state beyond `AppModel` (extended, not edited): the two models, what each thread was last asked,
/// today's ledger, and what the Settings pane shows. One for the app.
@MainActor
@Observable
final class AssistEngine {
    static let shared = AssistEngine()

    private(set) var onDeviceAvailable = false
    private(set) var onDeviceUnavailableReason: String?
    private(set) var haikuAvailable = false
    private(set) var ledger = AssistLedger(day: AssistLedger.dayKey())
    /// Seconds the last answer of each tier took.
    private(set) var lastLatency: [AssistTier: TimeInterval] = [:]

    @ObservationIgnored var history = AssistTriggers.History()
    @ObservationIgnored var memory = AssistMemory()
    @ObservationIgnored var onDevice: (any AssistModel)?
    @ObservationIgnored var haiku: (any AssistModel)?
    @ObservationIgnored var store: AssistLedgerStore?
    @ObservationIgnored var running: Set<AssistJob> = []
    @ObservationIgnored var tick: Task<Void, Never>?
    @ObservationIgnored var started = false

    func setAvailability(onDevice: Bool, reason: String?, haiku: Bool) {
        if onDeviceAvailable != onDevice { onDeviceAvailable = onDevice }
        if onDeviceUnavailableReason != reason { onDeviceUnavailableReason = reason }
        if haikuAvailable != haiku { haikuAvailable = haiku }
    }

    func setLedger(_ next: AssistLedger) {
        if ledger != next { ledger = next }
    }

    func noteLatency(_ seconds: TimeInterval, tier: AssistTier) {
        lastLatency[tier] = seconds
    }
}

/// What the assistant last said about a thread, shown in place of the deterministic activity line while the turn
/// goes on, and as a *seems stuck* mark when it says so (spec §4.10).
struct AssistNote: Equatable, Sendable {
    var activity: String?
    var stuckReason: String?
    var at: Date
    var tier: AssistTier

    var isStuck: Bool { stuckReason != nil }
}

/// The assistant (spec §4.10): runs the jobs `AssistTriggers` asks for, on the on-device model first and the driver's
/// light model second, and turns their labels into a sidebar caption, a mark, a quieter notification, an archive
/// hint and a topic. It never acts on its own: a stuck verdict is handed to the stuck trigger (`AppModel+ActingTriggers`).
extension AppModel {
    var assist: AssistEngine { AssistEngine.shared }

    /// How often the long-running check looks around when no event comes.
    static let assistTickInterval: Duration = .seconds(60)

    /// After the config is read and the drivers are loaded: the models, the ledger, the prewarm, the tick.
    func startAssist() {
        let engine = assist
        if engine.store == nil { engine.store = AssistLedgerStore(home: env.home) }
        refreshAssistModels()
        guard !engine.started else { return }
        engine.started = true
        let store = engine.store!
        Task { [weak self] in
            let ledger = await store.today()
            self?.assist.setLedger(ledger)
        }
        engine.tick = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.assistTickInterval)
                guard let self else { return }
                self.assist(on: .tick)
            }
        }
    }

    /// Picks the models the preference allows and says whether each can answer. Called at start and when the
    /// preference or the driver profiles change.
    func refreshAssistModels() {
        let engine = assist
        let mode = config.preferences.assist
        var onDeviceAvailable = false
        var reason: String? = "needs macOS 26"
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = (engine.onDevice as? FoundationAssistModel) ?? FoundationAssistModel()
            engine.onDevice = model
            reason = FoundationAssistModel.unavailableReason
            onDeviceAvailable = reason == nil
            if mode != .off, onDeviceAvailable {
                Task(priority: .utility) { await model.prewarm() }
            }
        }
        #endif
        let profile = drivers.profiles.first { $0.headlessAssist?.isEmpty == false && HeadlessAssistModel.isToolFree($0.headlessAssist ?? []) }
        if let profile {
            let home = env.home
            let shellResolver = env.shell
            Task(priority: .utility) { [weak self] in
                let shell = await shellResolver.environment()
                let runner = SubprocessHeadlessRunner(path: shell.path, shell: shell.shell)
                let model = HeadlessAssistModel(profile: profile, runner: runner, home: home, cwd: home)
                self?.assist.haiku = model
                self?.assist.setAvailability(onDevice: self?.assist.onDeviceAvailable ?? false,
                                             reason: self?.assist.onDeviceUnavailableReason, haiku: true)
            }
        } else {
            engine.haiku = nil
        }
        engine.setAvailability(onDevice: onDeviceAvailable, reason: reason, haiku: profile != nil && engine.haikuAvailable)
        if mode == .off {
            // A verdict from before the switch is no longer the assistant's to keep.
            for session in threads where session.assistNote != nil { session.setAssistNote(nil) }
        }
    }

    // MARK: Occasions

    /// Every thread as the triggers see it.
    private var assistSnapshots: [AssistTriggers.ThreadSnapshot] {
        threads.compactMap { session -> AssistTriggers.ThreadSnapshot? in
            guard session.isAlive, session.deliversEvents else { return nil }
            let task = task(of: session)
            let reply = session.activity.lastReply?.text ?? session.lastReply?.text ?? ""
            return AssistTriggers.ThreadSnapshot(
                id: session.id, state: session.displayState, turnStartedAt: session.activity.turnStartedAt,
                task: task?.id.rawValue, taskHasPullRequest: task.map { !$0.record.pullRequests.isEmpty } ?? false,
                replyLooksFinal: ArchiveHint.replyLooksFinal(reply))
        }
    }

    /// The jobs `occasion` asks for, started at utility priority; one of each at a time. Returns the jobs started.
    @discardableResult
    func assist(on occasion: AssistTriggers.Occasion) -> [AssistJob] {
        guard config.preferences.assist != .off, assistTier() != nil else { return [] }
        let engine = assist
        let jobs = AssistTriggers.jobs(for: occasion, threads: assistSnapshots, history: engine.history)
            .filter { !engine.running.contains($0) && $0.kind != .notificationTriage }
        for job in jobs {
            engine.running.insert(job)
            engine.history.ran(job, at: .now)
            Task(priority: .utility) { [weak self] in
                await self?.runAssistJob(job)
                self?.assist.running.remove(job)
            }
        }
        return jobs
    }

    /// A hook event landed on `session` (already folded in). Triage decides the notification, so it runs before
    /// `notifyIfNeeded`; the other jobs run beside it.
    func assistThenNotify(_ event: AdapterEvent, session: ThreadSession) {
        let engine = assist
        // A new prompt or a tool report: what the assistant said about the previous turn no longer holds.
        if event.kind == .turnStarted {
            if event.payload[HookEvent.toolKey].map(\.isEmpty) ?? true { session.setAssistNote(nil) }
            task(of: session)?.setArchiveHint(nil)
            engine.memory.turnStarted(session.id)
        } else if event.kind.changesState {
            session.setAssistNote(nil)
        }
        let occasion = AssistTriggers.Occasion.hook(thread: session.id, kind: event.kind)
        guard config.preferences.assist != .off, let tier = assistTier(), let model = assistModel(tier) else {
            notifyIfNeeded(event, session: session)
            return
        }
        let wanted = AssistTriggers.jobs(for: occasion, threads: assistSnapshots, history: engine.history)
        assist(on: occasion)
        let triage = AssistJob.triage(session.id)
        // Only when the verdict can change something: a notification that would go anyway, or not go at all, is
        // not worth a call (`AssistTriggers.triageMatters`).
        guard wanted.contains(triage), !engine.running.contains(triage),
              AssistTriggers.triageMatters(kind: event.kind, appIsActive: NSApplication.shared.isActive,
                                           quietsInformational: config.preferences.assistQuietsInformational),
              let said = ThreadNotificationContent.Said.from(event, activity: session.activity) else {
            notifyIfNeeded(event, session: session)
            return
        }
        let text = switch said {
        case .question(let text): "The agent asks:\n" + TranscriptTail.quoting(text)
        case .reply(let text): "The agent's last message:\n" + TranscriptTail.quoting(text)
        case .request(let text): "The agent asks permission to run:\n" + TranscriptTail.quoting(text)
        }
        let input = TranscriptTail.tokens(in: text) > TranscriptTail.defaultTokenBudget
            ? String(text.suffix(TranscriptTail.defaultTokenBudget * TranscriptTail.charactersPerToken)) : text
        // The same words as last time: the verdict holds, and what it decided was done then — a late copy of the
        // event, or a thread re-reporting its answer, brings no second notification.
        if let known = engine.memory.triage(of: session.id, for: input) {
            guard !known.handled else { return }
            engine.memory.markHandled(session.id)
            notifyIfNeeded(event, session: session, triage: known.verdict)
            return
        }
        engine.running.insert(triage)
        engine.history.ran(triage, at: .now)
        Task(priority: .utility) { [weak self] in
            let verdict: NotificationTriage? = await self?.ask(model, instructions: NotificationTriage.instructions,
                                                                 input: input, schema: NotificationTriage.schema, job: triage)
            guard let self else { return }
            self.assist.running.remove(triage)
            if let verdict {
                Usage.record(.assist, "assist.triage.\(UsageID.slug(verdict.kind.rawValue))", source: .app, context: tier.rawValue)
                self.assist.memory.rememberTriage(of: session.id, for: input, verdict: verdict, handled: true)
            }
            self.notifyIfNeeded(event, session: session, triage: verdict)
        }
    }

    /// A task was just created: a topic from the scope's, when it has some and the preference says so.
    func assistTaskCreated(_ task: TaskState) {
        guard config.preferences.assistPicksTopic else { return }
        let topics = topics(in: task.scopeID).filter { TaskTopic.key($0) != task.record.topic.map(TaskTopic.key) }
        let occasion = AssistTriggers.Occasion.taskCreated(task: task.id.rawValue, hasTopic: task.record.topic != nil,
                                                           topicsAvailable: !topics.isEmpty)
        assist(on: occasion)
    }

    /// The thread is closed for good.
    func forgetAssist(_ id: ThreadID) {
        assist.history.forget(id)
        assist.memory.forget(id)
    }

    // MARK: Jobs

    private func runAssistJob(_ job: AssistJob) async {
        guard let tier = assistTier(), let model = assistModel(tier) else { return }
        switch job.kind {
        case .threadDigest:
            await runDigest(job, model: model, tier: tier)
        case .archiveHint:
            await runArchiveHint(job, model: model, tier: tier)
        case .topicPick:
            await runTopicPick(job, model: model, tier: tier)
        case .notificationTriage:
            break
        }
    }

    private func runDigest(_ job: AssistJob, model: any AssistModel, tier: AssistTier) async {
        guard let id = job.thread, let session = session(id), session.isAlive, session.displayState == .running else { return }
        let lines = TerminalBridge.transcript(of: session).lines
        // Nothing printed since the last digest: what it said still holds, and asking again would only say it again.
        let fingerprint = TranscriptTail.fingerprint(of: lines)
        guard !assist.memory.digestIsCurrent(for: id, tailFingerprint: fingerprint) else { return }
        let input = "Terminal tail:\n" + TranscriptTail.quoted(lines)
        guard var digest: ThreadDigest = await ask(model, instructions: ThreadDigest.instructions, input: input,
                                                   schema: ThreadDigest.schema, job: job) else { return }
        assist.memory.rememberDigest(of: id, tailFingerprint: fingerprint)
        var answeredBy = tier
        let prefs = config.preferences
        if AssistPlan.wantsSecondOpinion(on: digest, answeredBy: tier, mode: prefs.assist, haikuAvailable: assist.haikuAvailable,
                                         haikuCallsToday: assist.ledger.haikuCalls, dailyCap: prefs.assistDailyCap),
           let haiku = assist.haiku,
           let second: ThreadDigest = await ask(haiku, instructions: ThreadDigest.instructions, input: input,
                                                schema: ThreadDigest.schema, job: job) {
            digest = second
            answeredBy = .haiku
        }
        // The turn may have ended while the model read it: a verdict about a finished turn is noise.
        guard session.isAlive, session.displayState == .running else { return }
        let wasStuck = session.assistNote?.isStuck ?? false
        let note = AssistNote(activity: digest.caption, stuckReason: digest.stuckReason, at: .now, tier: answeredBy)
        session.setAssistNote(note)
        Usage.record(.assist, "assist.digest.\(digest.stuck ? "stuck" : "working")", source: .app, context: answeredBy.rawValue)
        // With the stuck trigger on, Scope relaunches it first and only tells the user past the cap.
        if note.isStuck, !wasStuck {
            if preference(.stuck).enabled { noteStuck(session, reason: note.stuckReason ?? "") }
            else { notifyStuck(session, reason: note.stuckReason ?? "") }
        }
    }

    private func runArchiveHint(_ job: AssistJob, model: any AssistModel, tier: AssistTier) async {
        guard config.preferences.assistSuggestsArchive, let id = job.thread, let session = session(id),
              let taskID = job.task.flatMap(TaskID.init(rawValue:)), let task = task(taskID), !task.record.isArchived,
              let reply = session.activity.lastReply?.text ?? session.lastReply?.text else { return }
        let text = "The task's brief:\n" + TranscriptTail.quoting(ThreadActivity.excerpt(task.record.prompt ?? "", limit: 600) ?? "")
            + "\n\nThe agent's last message:\n" + TranscriptTail.quoting(reply)
        let input = TranscriptTail.tokens(in: text) > TranscriptTail.defaultTokenBudget
            ? String(text.suffix(TranscriptTail.defaultTokenBudget * TranscriptTail.charactersPerToken)) : text
        guard let hint: ArchiveHint = await ask(model, instructions: ArchiveHint.instructions, input: input,
                                                schema: ArchiveHint.schema, job: job) else { return }
        Usage.record(.assist, "assist.archive.\(hint.looksFinished ? "finished" : "open")", source: .app, context: tier.rawValue)
        guard hint.looksFinished, !task.record.isArchived, self.task(taskID) != nil else { return }
        task.setArchiveHint(hint)
    }

    private func runTopicPick(_ job: AssistJob, model: any AssistModel, tier: AssistTier) async {
        guard let taskID = job.task.flatMap(TaskID.init(rawValue:)), let task = task(taskID), task.record.topic == nil else { return }
        let topics = topics(in: task.scopeID)
        guard !topics.isEmpty, let brief = task.record.prompt, !brief.isEmpty else { return }
        let input = TopicPick.input(brief: TranscriptTail.quoting(brief), topics: topics)
        guard let pick: TopicPick = await ask(model, instructions: TopicPick.instructions, input: input,
                                              schema: TopicPick.schema(topics: topics), job: job) else { return }
        let chosen = pick.validated(against: topics)
        Usage.record(.assist, "assist.topic.\(chosen == nil ? "none" : "picked")", source: .app, context: tier.rawValue)
        // The user or an agent may have filed it meanwhile: theirs wins.
        guard let chosen, let current = self.task(taskID), current.record.topic == nil else { return }
        await setTopic(chosen, for: [taskID])
    }

    /// One call, counted and timed; `nil` when the model failed, which is logged and otherwise silent.
    private func ask<T: Decodable & Sendable>(_ model: any AssistModel, instructions: String, input: String,
                                              schema: AssistSchema, job: AssistJob) async -> T? {
        let tier = model.tier
        let start = ContinuousClock.now
        do {
            let answer: T = try await model.classify(instructions: instructions, input: input, schema: schema)
            let elapsed = start.duration(to: .now)
            assist.noteLatency(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, tier: tier)
            if let store = assist.store { assist.setLedger(await store.count(tier)) }
            Log.app.info("assist \(job.kind.rawValue, privacy: .public) by \(tier.rawValue, privacy: .public) in \(elapsed, privacy: .public)")
            return answer
        } catch {
            Log.app.notice("assist \(job.kind.rawValue, privacy: .public) by \(tier.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Tiers

    /// The tier that answers now, from the preference, what is available and the cap.
    func assistTier() -> AssistTier? {
        let prefs = config.preferences
        return AssistPlan.tier(mode: prefs.assist, onDeviceAvailable: assist.onDeviceAvailable, haikuAvailable: assist.haikuAvailable,
                               haikuCallsToday: assist.ledger.haikuCalls, dailyCap: prefs.assistDailyCap)
    }

    private func assistModel(_ tier: AssistTier) -> (any AssistModel)? {
        switch tier {
        case .onDevice: assist.onDevice
        case .haiku: assist.haiku
        }
    }

    // MARK: What the user sees

    /// "Not stuck": the mark goes, and the verdict is counted as a false positive in the ledger and the usage log.
    func markNotStuck(_ id: ThreadID) {
        guard let session = session(id), let note = session.assistNote, note.isStuck else { return }
        session.setAssistNote(AssistNote(activity: note.activity, stuckReason: nil, at: note.at, tier: note.tier))
        cancelStuck(id)
        Usage.record(.assist, "assist.digest.stuck", source: .user, context: "false-positive")
        clearNotifications(for: id)
        if let store = assist.store {
            Task { [weak self] in
                let ledger = await store.countFalsePositive()
                self?.assist.setLedger(ledger)
            }
        }
    }

    /// "Not blocking", from the notification a finished turn got because the assistant read it as a question or a
    /// failure: the thread is marked read, the words are remembered as informational so they bring nothing more, and
    /// the verdict is counted as a false positive in the ledger and the usage log.
    func markNotBlocking(_ id: ThreadID) {
        guard session(id) != nil else { return }
        assist.memory.overruleTriage(of: id)
        Usage.record(.assist, "assist.triage.blockingquestion", source: .user, context: "false-positive")
        markRead(id)
        clearNotifications(for: id)
        if let store = assist.store {
            Task { [weak self] in
                let ledger = await store.countFalsePositive()
                self?.assist.setLedger(ledger)
            }
        }
    }

    /// The archive hint is a proposal: this is its "no".
    func dismissArchiveHint(_ task: TaskState) {
        task.setArchiveHint(nil)
        Usage.record(.assist, "assist.archive.dismissed", source: .user)
    }

    private func notifyStuck(_ session: ThreadSession, reason: String) {
        guard !NSApplication.shared.isActive, let scope = scope(session.record.scopeID) else { return }
        let parts = [session.profile.name, scope.name] + (task(of: session).map { [$0.name] } ?? [])
        let content = ThreadNotificationContent(title: parts.joined(separator: " · "), subtitle: "seems stuck",
                                                body: reason.isEmpty ? "The agent looks like it is going in circles." : reason)
        notifier.post(content, threadID: session.id)
    }
}
