import AppKit
import Foundation
import ScopeAdapters
import ScopeControl
import ScopeCore
import ScopeDrivers
import ScopeTasks
import SwiftTerm

/// One thread: its record, its driver profile, the terminal view it owns for its whole life, and the
/// process running inside. Everything happens on the main actor (SwiftTerm delivers there and the
/// session owns an `NSView`).
@MainActor
@Observable
final class ThreadSession: Identifiable {
    let id: ThreadID
    private(set) var record: ThreadRecord
    let profile: DriverProfile

    /// Created on first access (a restored record costs nothing until its tab is shown), with the
    /// 800 × 480 frame and the palette of the current appearance. Never touched off the main actor.
    @ObservationIgnored private var _terminalView: LocalProcessTerminalView?
    var terminalView: LocalProcessTerminalView {
        if let _terminalView { return _terminalView }
        let view = ScopeTerminalView(frame: TerminalAppearance.initialFrame,
                                     font: TerminalAppearance.font,
                                     options: TerminalAppearance.options)
        TerminalAppearance.apply(to: view)
        view.processDelegate = bridge
        view.onUserInput = { [weak self] bytes in self?.handleUserInput(bytes) }
        view.onOpenLink = { [weak self] link in
            guard let self else { return false }
            return self.onOpenLink?(self, link) ?? false
        }
        _terminalView = view
        return view
    }

    @ObservationIgnored private let bridge = TerminalBridge()

    private(set) var phase: ProcessPhase = .notStarted
    /// State from adapter events (and the user's keystrokes); `nil` until the first one, and for good without an
    /// adapter (a plain shell).
    private(set) var adapterState: ThreadState?
    /// Error code of the turn that ended as `failed` (`rate_limit`, …); `nil` otherwise.
    private(set) var lastFailure: String?
    /// What the agent answered at the end of its last turn, when its driver says (`thread.read` with `reply`).
    /// Not drawn anywhere, so not observed: a reply per turn must not redraw the sidebar.
    @ObservationIgnored private(set) var lastReply: AgentReply?
    /// What the driver has been doing, folded from its events (`ThreadActivity`). Changes on every tool call, so not
    /// observed either; `AppModel+Activity` loads and saves it.
    @ObservationIgnored private(set) var activity = ThreadActivity()
    /// Claude Code's own state beyond the turn: background work, sub-agents, the permission mode… (`ClaudeSession`).
    /// Observed, and only set when it moves; fed by every hook event, late ones included, and by the transcript.
    private(set) var claude = ClaudeSession()
    /// The sub-agent the Subagents card shows the detail of, picked there or from its sidebar row.
    var focusedSubagent: String?
    /// Where the transcript was last read up to (`AppModel+ClaudeSession`).
    @ObservationIgnored var transcriptTail = ClaudeTranscriptTail()
    @ObservationIgnored var transcriptTailReading = false
    /// A Claude Code session started, resumed or was cleared in this folder: its MCP configuration is read again
    /// (`AppModel+ClaudeSession`).
    @ObservationIgnored var onClaudeSessionStarted: (@MainActor (ThreadSession, String) -> Void)?
    /// The session opened, merged or linked pull requests it had not reported yet (`ClaudeSessionPullRequests`).
    @ObservationIgnored var onClaudePullRequests: (@MainActor (ThreadSession, [ClaudeSessionPullRequests.Entry]) -> Void)?
    /// Times each sub-agent's `meta.json` was looked for and not found: given up on after a few.
    @ObservationIgnored var subagentMetaMisses: [String: Int] = [:]
    /// When the last running sub-agent finished, by hook or by the transcript (`ThreadWait.Snapshot.subagentsEndedAt`).
    @ObservationIgnored private(set) var subagentsEndedAt: Date?
    /// The activity in words, for the sidebar and the toolbar (`ThreadActivityHeadline`). Observed, and only set
    /// when the words move: a tool call on the same file, or a second permission prompt, redraws nothing.
    private(set) var activityHeadline: ThreadActivityHeadline?
    /// What the assistant last said about the turn in progress (spec §4.10); `nil` once the turn is over.
    private(set) var assistNote: AssistNote?
    /// Bumped when a turn opens or closes, or the agent's plan moves: what the task timeline and the Plan card redraw
    /// on, since `activity` itself is not observed.
    private(set) var turnRevision = 0
    /// `3/7 steps` while the agent's plan has steps left (`AgentPlan.summary`); `nil` otherwise. Observed, and only
    /// set when the words move: the sidebar caption ends with it.
    private(set) var planSummary: String?
    /// How full the driver's context window is, with its model and version (`ThreadActivity.contextWindow`), observed
    /// for the Context card: set only when the report moved, so a status line that repeats itself redraws nothing.
    private(set) var contextWindow: ContextWindowReport?
    /// Called when the activity changed in a way worth keeping across a restart (a turn closed, a reply, a
    /// transcript) — not on each tool call, which only moves `lastTool`.
    @ObservationIgnored var onActivityChanged: (@MainActor (ThreadSession) -> Void)?
    /// When the thread was handed a prompt its driver has not reported on yet (`ThreadWait`).
    @ObservationIgnored private(set) var expectingTurnSince: Date?
    /// When the thread was last handed a prompt, reported on or not: a reply older than this answers something else.
    @ObservationIgnored private(set) var lastPromptAt: Date?
    /// When the last `turn.started` was applied (a prompt or a tool report): `ThreadWait`'s safety net under `running`.
    @ObservationIgnored private(set) var lastTurnStartedAt: Date?
    /// OSC 0/2 title.
    private(set) var terminalTitle: String?
    /// OSC 7 directory, decoded from its `file://` form.
    private(set) var reportedDirectory: String?
    /// Where the driver last said it was working (the folder of the file a tool touched, from its hooks). A
    /// driver's terminal never reports a directory, so this is what tells the repositories of a task apart.
    private(set) var agentDirectory: String?
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var lastError: LaunchError?
    private(set) var hasLaidOut = false

    @ObservationIgnored private var pendingPlan: LaunchPlan?
    @ObservationIgnored private var inputTracker = TerminalInputTracker()
    @ObservationIgnored private var layoutFallback: Task<Void, Never>?
    /// Divider printed by the next start instead of "relaunched …" (the auto-relaunch says why it started).
    @ObservationIgnored var nextLaunchNotice: String?
    /// The relaunched thread is being asked to go on with the turn the restart cut short (`InterruptedTurn`): the
    /// caption says so until the message is typed or dropped.
    private(set) var resumingAfterRestart = false
    /// When the user last submitted a prompt or an interrupt at the terminal of a driver that reports turns
    /// (`TerminalInputSignal`; raw bytes would count the terminal's own replies to the driver's queries). What
    /// the restart message yields to: a user already talking to the thread does not want Scope's prompt under theirs.
    @ObservationIgnored private(set) var lastUserInputAt: Date?
    /// When the driver last said a session of it started (`sessionStarted`): its prompt is up from there on.
    @ObservationIgnored private(set) var lastSessionStartedAt: Date?

    /// Called on every record change so `AppModel` persists it.
    @ObservationIgnored var onRecordChanged: (@MainActor (ThreadRecord) -> Void)?
    /// Called when the process exits (after the record was updated).
    @ObservationIgnored var onExit: (@MainActor (ThreadSession, ExitStatus) -> Void)?
    /// A link clicked in the terminal; `true` when it was shown in the app.
    @ObservationIgnored var onOpenLink: (@MainActor (ThreadSession, String) -> Bool)?

    /// How long a deferred launch waits for the first layout before starting on the default frame.
    static let layoutFallbackDelay: Duration = .milliseconds(250)

    init(record: ThreadRecord, profile: DriverProfile) {
        self.id = record.id
        self.record = record
        self.profile = profile
        if record.lastState == .exited, let exit = record.lastExit {
            phase = .exited(exit)
        }
        bridge.session = self
    }

    /// Live rename: the record is updated and persisted through `onRecordChanged`; `title` (and every
    /// row / tab observing it) follows at once.
    func setTitle(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != record.title else { return }
        record.title = title
        onRecordChanged?(record)
    }

    /// The record as somebody changed it on disk (`AppModel.applyExternalThreadChanges`): what describes the thread
    /// is taken (title, model, cwd, task, origin, role, the relaunch opt-out), what the running process knows better
    /// than any file is kept (its state, its exits, its launches, the session id its adapter captured). Not
    /// persisted: the file is the source here, and writing it back would only re-encode it.
    func takeRecord(fromDisk external: ThreadRecord) {
        var next = external
        next.processAlive = record.processAlive
        next.lastState = record.lastState
        next.lastExit = record.lastExit
        next.lastLaunchedAt = record.lastLaunchedAt
        next.launchCount = record.launchCount
        next.resumeID = record.resumeID
        next.interruptedTurn = record.interruptedTurn
        guard next != record else { return }
        record = next
    }

    /// The thread's opt-out of auto-relaunch.
    func setRelaunchesAtStartup(_ relaunches: Bool) {
        guard relaunches != record.relaunchesAtStartup else { return }
        record.relaunchesAtStartup = relaunches
        onRecordChanged?(record)
    }

    /// Makes an ordinary thread of a resident one (a second claim on its role) or the reverse.
    func setResident(_ role: ResidentRole?) {
        guard role != record.resident else { return }
        record.resident = role
        onRecordChanged?(record)
    }

    /// The thread was running when the app went down and stays stopped this time (auto-relaunch off, skipped or
    /// blocked): it must not come back at a later launch either.
    func forgetProcessAlive() {
        guard record.processAlive else { return }
        record.processAlive = false
        onRecordChanged?(record)
    }

    // MARK: Interrupted turn

    /// The app is going down with this thread's turn in progress: stamped on the record, which the caller writes.
    func markInterruptedTurn(at date: Date = .now) {
        record = InterruptedTurn.marking(record, state: isAlive ? adapterState : nil, at: date)
    }

    /// The interruption was considered (asked about, or not for a reason): a later launch must not ask again.
    func consumeInterruptedTurn() {
        guard record.interruptedTurn != nil else { return }
        record = InterruptedTurn.consumed(record)
        onRecordChanged?(record)
    }

    func setResumingAfterRestart(_ resuming: Bool) {
        guard resuming != resumingAfterRestart else { return }
        resumingAfterRestart = resuming
        refreshActivityHeadline()
    }

    // MARK: Derived

    var title: String { record.title }
    var isAlive: Bool { phase.isAlive }
    var pid: pid_t? { phase.pid }
    var canResume: Bool { profile.canResume && record.resumeID != nil }

    /// The sidebar / tab / pill state: alive → adapter state (`idle` until a driver that reports events has said
    /// anything, `running` for one that never will); launching → `idle`; anything else → `exited`.
    var displayState: ThreadState {
        switch phase {
        case .alive: adapterState ?? (deliversEvents ? .initial : .running)
        case .launching: .idle
        case .notStarted, .exited, .failed: .exited
        }
    }

    /// `true` while the driver itself says a turn is in progress, as opposed to "alive, nothing known" (a shell,
    /// a driver without a wired adapter). Only this one is drawn as activity.
    var isWorking: Bool { phase.isAlive && adapterState == .running }

    /// The profile's adapter reports turns (Claude Code hooks, Codex `notify`).
    var deliversEvents: Bool { AdapterInstaller.deliversEvents(profile) }

    // MARK: Launch

    func markLaunching() {
        lastError = nil
        phase = .launching
    }

    func fail(_ error: LaunchError) {
        pendingPlan = nil
        layoutFallback?.cancel()
        layoutFallback = nil
        lastError = error
        phase = .failed(error.title)
        nextLaunchNotice = nil
        forgetProcessAlive()
    }

    /// Starts now when the view has been laid out at least once, otherwise on the first layout (so the
    /// child is forked with the real cols × rows) or after 250 ms on the default frame, whichever comes first.
    func launch(_ plan: LaunchPlan) {
        lastError = nil
        if hasLaidOut {
            start(plan)
            return
        }
        pendingPlan = plan
        phase = .launching
        layoutFallback?.cancel()
        layoutFallback = Task { [weak self] in
            try? await Task.sleep(for: ThreadSession.layoutFallbackDelay)
            guard !Task.isCancelled, let self, let plan = self.pendingPlan else { return }
            self.pendingPlan = nil
            self.start(plan)
        }
    }

    private func start(_ plan: LaunchPlan) {
        layoutFallback?.cancel()
        layoutFallback = nil
        pendingPlan = nil
        let view = terminalView
        guard !view.process.running else {
            Log.threads.error("thread \(self.id.rawValue, privacy: .public): start requested while a process is running")
            return
        }
        if let notice = nextLaunchNotice {
            printNotice(notice)
        } else if record.launchCount > 0 {
            printNotice("relaunched \(Date.now.formatted(date: .omitted, time: .standard))")
        }
        nextLaunchNotice = nil
        view.startProcess(
            executable: plan.executable,
            args: plan.arguments,
            environment: plan.envp,
            execName: plan.argv0,
            currentDirectory: plan.cwd
        )
        guard view.process.running else {
            fail(.forkFailed)
            return
        }
        adapterState = nil
        lastFailure = nil
        // The grace for a turn to start runs from the driver's start, not from a setup it waited behind.
        if expectingTurnSince != nil { expectingTurnSince = .now }
        inputTracker = TerminalInputTracker()
        phase = .alive(pid: view.process.shellPid, since: .now)
        refreshActivityHeadline()
        record.lastLaunchedAt = .now
        record.launchCount += 1
        record.lastExit = nil
        record.lastState = .initial
        record.processAlive = true
        onRecordChanged?(record)
        Log.threads.info("thread \(self.id.rawValue, privacy: .public) started pid \(view.process.shellPid): \(plan.displayCommand, privacy: .public)")
    }

    // MARK: Stop

    /// SIGHUP now (what Terminal.app does when its window closes), SIGKILL if the same pid is still alive
    /// after `seconds`. The exit path then runs normally through `processTerminated`.
    ///
    /// The shell leads its own process group (the PTY made it a session leader): the group gets the signal too,
    /// so what it started without job control goes with it. Detached processes are the task sweep's job.
    func stop(escalateAfter seconds: Double = 3) {
        guard let view = _terminalView, view.process.running else { return }
        let pid = view.process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        if getpgid(pid) == pid { kill(-pid, SIGHUP) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let view = self._terminalView, view.process.running, view.process.shellPid == pid else { return }
            Log.threads.warning("thread \(self.id.rawValue, privacy: .public): pid \(pid) ignored SIGHUP, sending SIGKILL")
            kill(pid, SIGKILL)
            if getpgid(pid) == pid { kill(-pid, SIGKILL) }
        }
    }

    // MARK: Input / output

    func send(_ text: String) {
        if let view = terminalView as? ScopeTerminalView {
            view.write(text)
        } else {
            terminalView.send(txt: text)
        }
    }

    /// Types `text` as one input — a paste when the program enabled bracketed paste, so a multiline message is not
    /// submitted at its first line break — then presses ↩ on its own once the program had time to read it
    /// (`ThreadDelivery.submitDelay`). Sent in one write, the ↩ lands in the same read as the text and a TUI such
    /// as Claude Code takes it for part of the paste: a newline in the prompt and nothing submitted.
    ///
    /// A draft the user left in Claude Code's field is stashed first and comes back once the message is submitted
    /// (`ClaudeDraft`); their keys wait meanwhile, so nothing they type lands inside the message.
    ///
    /// Submissions go out one after the other: a second message typed before the first one's ↩ would join it.
    func submit(_ text: String) {
        expectTurn()
        let previous = pendingSubmit
        pendingSubmit = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.phase.isAlive else { return }
            guard !text.isEmpty else {
                self.send("\r")
                return
            }
            await self.submitKeepingDraft(text)
        }
    }

    @ObservationIgnored private var pendingSubmit: Task<Void, Never>?
    /// The user pressed Ctrl+S since their last submit: Claude Code may hold a stash the hint row does not show.
    @ObservationIgnored private var userStashed = false

    private func submitKeepingDraft(_ text: String) async {
        // Only Claude Code has a field to read; anything else gets the message as it always has.
        guard profile.adapter?.kind == ClaudeHooksAdapter.kind else {
            await typeAndSubmit(text)
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        var field = promptInput()
        var plan = draftPlan(field, waited: .zero)
        while plan == .wait {
            try? await Task.sleep(for: .milliseconds(250))
            guard phase.isAlive else { return }
            field = promptInput()
            plan = draftPlan(field, waited: clock.now - start)
        }
        guard plan != .asIs, let draft = field, let view = terminalView as? ScopeTerminalView else {
            await typeAndSubmit(text)
            return
        }
        view.holdUserInput()
        defer { view.releaseUserInput() }
        if plan == .stash, draft.stashHeld || userStashed {
            Log.threads.notice("thread \(self.id.rawValue, privacy: .public): the draft replaces an older stash")
        }
        send(plan == .stash ? ClaudeDraft.stash : ClaudeDraft.leaveShell)
        if await !settle(ClaudeDraft.isCleared) {
            Log.threads.warning("thread \(self.id.rawValue, privacy: .public): the field did not clear; message typed after the draft")
        }
        guard await typeAndSubmit(text) else { return }
        switch plan {
        case .stash:
            if await settle({ ClaudeDraft.isRestored(draft, on: $0) }) { return }
            // Claude Code puts a stash back on submit; one still waiting is brought back by hand.
            if ClaudeDraft.needsUnstash(promptInput()) {
                send(ClaudeDraft.stash)
                _ = await settle { ClaudeDraft.isRestored(draft, on: $0) }
            } else {
                Log.threads.warning("thread \(self.id.rawValue, privacy: .public): the stashed draft did not show again")
            }
        case .leaveShell:
            if await settle(ClaudeDraft.isCleared) { send(ClaudeDraft.enterShell) }
        case .asIs, .wait:
            break
        }
    }

    private func draftPlan(_ field: ClaudePromptInput?, waited: Duration) -> ClaudeDraft.Plan {
        ClaudeDraft.plan(claudeInput: true, dialog: claude.pending.current != nil, field: field, userStashed: userStashed,
                         waited: waited)
    }

    /// `false` when the process went away before ↩.
    @discardableResult
    private func typeAndSubmit(_ text: String) async -> Bool {
        let input = ThreadDelivery.input(text, bracketedPasteMode: terminalView.getTerminal().bracketedPasteMode)
        send(input)
        try? await Task.sleep(for: ThreadDelivery.submitDelay(forByteCount: input.utf8.count))
        guard phase.isAlive else { return false }
        send("\r")
        // Submitting puts any stash back into the field: none is left.
        userStashed = false
        return true
    }

    /// Reads Claude Code's field until `done` holds, at most `ClaudeDraft.settleTimeout`.
    private func settle(_ done: (ClaudePromptInput?) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < ClaudeDraft.settleTimeout {
            try? await Task.sleep(for: ClaudeDraft.pollInterval)
            guard phase.isAlive else { return false }
            if done(promptInput()) { return true }
        }
        return false
    }

    /// Claude Code's input field as the screen shows it now (`ClaudePromptInput`).
    func promptInput() -> ClaudePromptInput? {
        ClaudePromptInput.read(TerminalBridge.screenRows(of: self))
    }

    /// Feeds a divider line into the emulator (not to the child).
    func printNotice(_ text: String) {
        terminalView.feed(text: "\r\n\u{1b}[2m── \(text) ──\u{1b}[0m\r\n")
    }

    // MARK: Adapter

    func resetAdapterState() {
        adapterState = nil
        refreshActivityHeadline()
    }

    /// The thread was just handed a prompt: until its driver reports something, it counts as at work.
    func expectTurn() {
        expectingTurnSince = .now
        lastPromptAt = .now
    }

    /// What `thread.wait` looks at.
    var waitSnapshot: ThreadWait.Snapshot {
        let starting = if case .launching = phase { true } else { false }
        return ThreadWait.Snapshot(state: displayState.name, expectingSince: expectingTurnSince,
                                   reportsTurnStart: AdapterInstaller.reportsTurnStart(profile), starting: starting,
                                   replyAt: lastReply?.at, turnStartedAt: lastTurnStartedAt, lastPromptAt: lastPromptAt,
                                   agents: phase.isAlive ? runningSubagents() : 0, subagentsEndedAt: subagentsEndedAt)
    }

    /// Sub-agents still at work: the hooks' count (`ThreadActivity.agents`) checked against what the session's
    /// transcript says ended, plus launches whose start hook was lost (`ClaudeSubagents.runningCount`). A process
    /// that is gone keeps the hooks' word alone: nothing tells the transcript it died.
    func runningSubagents(now: Date = .now) -> Int {
        guard phase.isAlive else { return activity.runningAgents(now: now) }
        return claude.subagents.runningCount(hookAgents: activity.agents, now: now, limit: ThreadActivity.agentLimit)
    }

    /// `running`, yet the agent answered after anything that started a turn (`ThreadWait.hasOutlivedItsTurn`): the
    /// turn is over, whatever put the state back. Settled to `done` so the sidebar and `scope list` agree with the wait.
    func settleOutlivedTurn() {
        guard phase.isAlive, adapterState == .running, ThreadWait.hasOutlivedItsTurn(waitSnapshot) else { return }
        Log.threads.notice("thread \(self.id.rawValue, privacy: .public) still read running after its last answer; now done")
        setAdapterState(.done)
    }

    /// Returns `false` when the event was ignored: the process is gone, or the event belongs to a turn already over.
    @discardableResult
    func apply(_ event: AdapterEvent) -> Bool {
        guard phase.isAlive else { return false }
        // Before the turn logic: what Claude Code reports between turns is still news here.
        if let facts = ClaudeHookFacts.from(event) {
            updateClaude { $0.apply(facts) }
            if facts.event == "SessionStart" { onClaudeSessionStarted?(self, facts.body["cwd"]?.nonEmptyString ?? record.cwd) }
        }
        // `permission_prompt` came: the dialog sat six seconds, the early confirmation needs no more checking.
        if event.kind == .permissionRequested, event.payload[HookEvent.viaKey] == HookEvent.viaNotification { confirmedEarly = nil }
        // Decided on the activity before the event: a report that belongs to a turn already over moves nothing.
        let promptPending = expectingTurnSince != nil
        let late = activity.isLate(event, promptPending: promptPending)
        let subagentsBefore = event.kind == .agentEnded ? runningSubagents() : 0
        var next = ThreadStateMachine.next(adapterState ?? .initial, on: event, after: activity, promptPending: promptPending)
        // Two permissions asked together are answered one after the other: the first one's tool report does not end
        // the wait on the second, still up (`ClaudePendingRequests`).
        if next == .running, event.kind == .turnStarted, !(event.payload[HookEvent.toolKey] ?? "").isEmpty,
           let reason = claude.pending.waitReason {
            next = .waiting(reason: reason)
        }
        if event.kind.changesState, !late { expectingTurnSince = nil }
        if event.kind == .turnStarted, !late { lastTurnStartedAt = event.receivedAt }
        if event.kind == .sessionStarted { lastSessionStartedAt = event.receivedAt }
        if let reply = AgentReply.from(event) { lastReply = reply }
        setActivity(activity.apply(event, promptPending: promptPending))
        // The last background sub-agent reported between turns: the driver is about to open a turn on its result.
        // Expected like a prompt, so a wait does not slip through the gap — but not a prompt: the last answer stays
        // the answer it is, and `startGrace` lets the thread go if no turn follows.
        if subagentsBefore > 0, runningSubagents() == 0 { subagentsEndedAt = event.receivedAt }
        if event.kind == .agentEnded, !activity.inTurn, runningSubagents() == 0, expectingTurnSince == nil,
           adapterState != .running {
            expectingTurnSince = event.receivedAt
        }
        // Each write below is skipped when it changes nothing. An observed property notifies on every set, equal
        // or not, and a hook event arrives per tool call: the toolbar and the sidebar were rebuilt each time for a
        // state that had not moved.
        if adapterState != next { adapterState = next }
        refreshActivityHeadline()
        let failure = next == .failed ? (event.payload[HookEvent.errorKey] ?? lastFailure) : nil
        if lastFailure != failure { lastFailure = failure }
        if record.lastState != next { record.lastState = next }
        if let directory = event.payload[HookEvent.directoryKey], !directory.isEmpty, agentDirectory != directory {
            agentDirectory = directory
        }
        if let session = event.payload["session_id"] ?? event.payload["resume_id"], !session.isEmpty,
           record.resumeID != session {
            record.resumeID = session
        }
        onRecordChanged?(record)
        return !late
    }

    /// A `limits.reported` event: the status line said how full the context window is. Only the activity moves —
    /// the state machine has nothing to say about it, and the record is not touched.
    func receiveStatus(_ event: AdapterEvent) {
        guard event.kind == .limitsReported, event.payload[HookEvent.contextKey] != nil else { return }
        setActivity(activity.apply(event))
    }

    /// Folds what the transcript gained.
    func applyTranscript(_ records: [ClaudeTranscriptRecord]) {
        guard !records.isEmpty else { return }
        let started = if case .alive(_, let since) = phase { since } else { Date?.none }
        let runningBefore = runningSubagents()
        updateClaude { session in
            // Before the records: what a relaunch reads back from an earlier process is not running any more.
            if let started { session.subagents.processStarted(at: started) }
            session.apply(records)
        }
        // The last background sub-agent reported in the transcript (its notification) rather than by a hook: the
        // driver is about to open a turn on its result, expected as after `agent.ended` in `apply(_:)`.
        // "No" in a permission dialog fires no hook: the turn just ends, which only the transcript says. The thread
        // then waits on nothing.
        // Only a turn end written after the wait began: a transcript read from its start replays every earlier one.
        let waitBegan = activity.turns.last?.endedAt ?? .distantFuture
        let turnEnded = records.contains { if case .turnDuration(let turn) = $0 { (turn.at ?? .distantPast) > waitBegan } else { false } }
        if turnEnded, phase.isAlive, adapterState == .waiting(reason: .permission), claude.pending.current == nil {
            setAdapterState(.idle)
        }
        guard runningBefore > 0, runningSubagents() == 0 else { return }
        subagentsEndedAt = .now
        if !activity.inTurn, expectingTurnSince == nil, adapterState != .running { expectingTurnSince = .now }
    }

    /// What the configuration declares for the session's MCP servers (`ClaudeMCPConfig`).
    func declareMCPServers(_ declarations: [ClaudeMCPServers.Declaration]) {
        updateClaude { $0.mcpServers.declare(declarations) }
    }

    /// Scope is about to signal background task `id` (`AppModel.stopBackgroundTask`).
    func markBackgroundStopRequested(_ id: String) {
        updateClaude { $0.background.markStopRequested(id) }
    }

    /// Folds the `meta.json` files read for its sub-agents: (agent id, meta, the sub-agent's transcript beside it).
    func applySubagentMeta(_ metas: [(agentID: String, meta: ClaudeSubagentMeta, transcript: String)]) {
        guard !metas.isEmpty else { return }
        updateClaude { session in
            for entry in metas { session.subagents.apply(entry.meta, agentID: entry.agentID, transcriptPath: entry.transcript) }
        }
    }

    /// Writes `claude` only when it moved: it is observed, and a hook arrives per tool call. What it asks words the
    /// activity line.
    private func updateClaude(_ change: (inout ClaudeSession) -> Void) {
        var next = claude
        change(&next)
        guard next != claude else { return }
        let previous = claude
        claude = next
        if next.compactions.isRunning != previous.compactions.isRunning || next.pending.current != previous.pending.current {
            refreshActivityHeadline()
        }
        let reported = next.pullRequests.changes(since: previous.pullRequests)
        if !reported.isEmpty { onClaudePullRequests?(self, reported) }
    }

    /// `claude agents` says the dialog of the permission described last is up (`AppModel.confirmPermissionSoon`):
    /// the id of the request it confirmed.
    func confirmPermission() -> String? {
        var confirmed: String?
        updateClaude { confirmed = $0.pending.confirmPermission() }
        return confirmed
    }

    /// The request `claude agents` confirmed before `permission_prompt` did, while that notification has not come:
    /// another hook may still decide it (`AppModel.confirmPermissionSoon`).
    @ObservationIgnored var confirmedEarly: String?

    /// The session no longer waits on the permission `claude agents` had confirmed early: another hook decided it.
    /// Its tool runs (or was refused) and no hook says so before it ends.
    func decidedElsewhere(_ id: String) {
        confirmedEarly = nil
        updateClaude { $0.pending.remove(id: id) }
        if adapterState == .waiting(reason: .permission), claude.pending.waitReason == nil { setAdapterState(.running) }
    }

    /// The permission request a notification was last posted for: `permission_prompt` arriving after
    /// `claude agents` already said so must not ring a second time.
    @ObservationIgnored var notifiedRequestID: String?

    /// Scope typed an answer to `id`: it is no longer asked, whatever the hooks say next.
    func answered(_ id: String) {
        updateClaude { $0.pending.remove(id: id) }
    }

    /// Replaces the activity; `onActivityChanged` only when what is saved moved.
    func setActivity(_ next: ThreadActivity) {
        let previous = activity
        activity = next
        refreshActivityHeadline()
        let planMoved = next.plan != previous.plan
        if next.turns != previous.turns || next.inTurn != previous.inTurn || planMoved { turnRevision &+= 1 }
        let summary = next.plan.flatMap { $0.isInProgress ? $0.summary : nil }
        if planSummary != summary { planSummary = summary }
        if next.contextWindow != contextWindow { contextWindow = next.contextWindow }
        // The context report is saved when its figure moves by a point, or the model or version changes: a status line
        // after `Stop` would otherwise live in memory only, and the gauge vanish at the next launch. Not on every
        // status line, which comes with each message.
        let contextMoved = Self.savedContext(next.contextWindow) != Self.savedContext(previous.contextWindow)
        if next.turns != previous.turns || next.lastReply != previous.lastReply
            || next.transcriptPath != previous.transcriptPath || next.inTurn != previous.inTurn || contextMoved || planMoved {
            onActivityChanged?(self)
        }
    }

    /// What of a context report is worth a write: the rounded percentage, the model and the driver's version.
    private static func savedContext(_ report: ContextWindowReport?) -> [String?] {
        [report?.usedPercentage.map { String(Int($0.rounded())) }, report?.modelID, report?.modelName, report?.driverVersion]
    }

    private func refreshActivityHeadline() {
        var next = ThreadActivityHeadline.make(activity, state: displayState, compacting: claude.compactions.isRunning,
                                               pending: claude.pending.current)
        // Between the relaunch and the message that asks it to go on, "stopped mid-turn" is not what is happening.
        if resumingAfterRestart, phase.isAlive, displayState != .running {
            next = ThreadActivityHeadline(text: InterruptedTurn.headline)
        }
        // While the turn runs, the assistant's words beat the tool's: "Retrying the same test" says more than
        // "Running swift test", and a stuck verdict is the one thing the caption must show.
        if displayState == .running, let note = assistNote {
            if let reason = note.stuckReason {
                next = ThreadActivityHeadline(text: "Seems stuck — \(reason)", detail: reason)
            } else if let activity = note.activity {
                next = ThreadActivityHeadline(text: activity, detail: next?.detail)
            }
        }
        if activityHeadline != next { activityHeadline = next }
    }

    /// Replaces the assistant's note; the caption follows.
    func setAssistNote(_ note: AssistNote?) {
        guard note != assistNote else { return }
        assistNote = note
        refreshActivityHeadline()
    }

    /// Persists a driver session id captured elsewhere.
    func setResumeID(_ resumeID: String?) {
        record.resumeID = resumeID
        onRecordChanged?(record)
    }

    /// Mark as Read: a `waiting`, `done` or `failed` thread goes back to `idle` (`ThreadState.acknowledged`), in the
    /// record too so the sidebar, the badge and a restart agree. Anything else is left alone.
    func acknowledgeAttention() {
        guard let state = adapterState, state.acknowledged != state else { return }
        setAdapterState(state.acknowledged)
    }

    /// The user is looking at the thread: a finished turn is no longer news. A question stays until answered.
    func acknowledgeResult() {
        guard let state = adapterState, state.isUnreadResult else { return }
        setAdapterState(state.acknowledged)
    }

    /// Bytes the user typed into the terminal, on their way to the child: an interrupt, an approved permission or
    /// a prompt submitted to a driver that never reports a turn start moves the state (`TerminalInputSignal`).
    func handleUserInput(_ bytes: ArraySlice<UInt8>) {
        guard phase.isAlive, deliversEvents else { return }
        // A key in the dialog Claude Code shows decides it, and no hook says so before the tool has run.
        if claude.pending.current != nil {
            var keystroke = ClaudePendingRequests.Keystroke.none
            updateClaude { keystroke = $0.pending.userTyped(bytes) }
            if keystroke == .approved, adapterState == .waiting(reason: .permission), claude.pending.waitReason == nil {
                setAdapterState(.running)
            }
        }
        if bytes.elementsEqual(ClaudeDraft.stash.utf8), (terminalView as? ScopeTerminalView)?.isScopeWriting != true {
            userStashed = true
        }
        guard let signal = inputTracker.feed(bytes) else { return }
        if case .submit = signal { userStashed = false }
        if signal != .submit(hadText: false) { lastUserInputAt = .now }
        if signal == .interrupt, adapterState == .running {
            setActivity(activity.closingOpenTurn(as: .interrupted, at: .now))
        }
        guard var next = ThreadStateMachine.next(adapterState ?? .initial, onUserInput: signal,
                                                 adapterReportsTurnStart: AdapterInstaller.reportsTurnStart(profile))
        else { return }
        if next == .running, let reason = claude.pending.waitReason { next = .waiting(reason: reason) }
        setAdapterState(next)
    }

    private func setAdapterState(_ state: ThreadState) {
        adapterState = state
        refreshActivityHeadline()
        if state != .failed { lastFailure = nil }
        record.lastState = state
        onRecordChanged?(record)
    }

    // MARK: Callbacks from TerminalBridge / TerminalHostContainer

    func viewDidLayout() {
        hasLaidOut = true
        if let plan = pendingPlan {
            pendingPlan = nil
            start(plan)
        }
    }

    /// The only source of `.exited`.
    func handleExit(rawWaitStatus: Int32?) {
        let status = ExitStatus.decode(rawWaitStatus: rawWaitStatus)
        phase = .exited(status)
        adapterState = nil
        updateClaude { $0.pending = ClaudePendingRequests() }
        assistNote = nil
        resumingAfterRestart = false
        setActivity(activity.closingOpenTurn(at: .now))
        // Whatever the session ran in the background died with it.
        updateClaude { $0.background.sessionEnded(at: .now) }
        record.lastExit = status
        record.lastState = .exited
        record.processAlive = false
        onRecordChanged?(record)
        Log.threads.info("thread \(self.id.rawValue, privacy: .public) exited: \(status.summary, privacy: .public)")
        onExit?(self, status)
    }

    func handleTitle(_ title: String) {
        terminalTitle = title.isEmpty ? nil : title
    }

    func handleDirectory(_ directory: String?) {
        guard let directory, !directory.isEmpty else {
            reportedDirectory = nil
            return
        }
        // OSC 7 carries `file://host/percent%20encoded/path`.
        if let url = URL(string: directory), url.isFileURL {
            reportedDirectory = url.path(percentEncoded: false)
        } else {
            reportedDirectory = directory
        }
    }

    func handleSize(cols: Int, rows: Int) {
        columns = cols
        self.rows = rows
    }
}
