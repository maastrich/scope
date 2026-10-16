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
    /// The activity in words, for the sidebar and the toolbar (`ThreadActivityHeadline`). Observed, and only set
    /// when the words move: a tool call on the same file, or a second permission prompt, redraws nothing.
    private(set) var activityHeadline: ThreadActivityHeadline?
    /// Bumped when a turn opens or closes: what the task timeline redraws on, since `activity` itself is not observed.
    private(set) var turnRevision = 0
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
        terminalView.send(txt: text)
    }

    /// Types `text` as one input — a paste when the program enabled bracketed paste, so a multiline message is not
    /// submitted at its first line break — then presses ↩ on its own once the program had time to read it
    /// (`ThreadDelivery.submitDelay`). Sent in one write, the ↩ lands in the same read as the text and a TUI such
    /// as Claude Code takes it for part of the paste: a newline in the prompt and nothing submitted.
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
            let input = ThreadDelivery.input(text, bracketedPasteMode: self.terminalView.getTerminal().bracketedPasteMode)
            self.send(input)
            try? await Task.sleep(for: ThreadDelivery.submitDelay(forByteCount: input.utf8.count))
            guard self.phase.isAlive else { return }
            self.send("\r")
        }
    }

    @ObservationIgnored private var pendingSubmit: Task<Void, Never>?

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
                                   replyAt: lastReply?.at, turnStartedAt: lastTurnStartedAt, lastPromptAt: lastPromptAt)
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
        // Decided on the activity before the event: a report that belongs to a turn already over moves nothing.
        let promptPending = expectingTurnSince != nil
        let late = activity.isLate(event, promptPending: promptPending)
        let next = ThreadStateMachine.next(adapterState ?? .initial, on: event, after: activity, promptPending: promptPending)
        if event.kind.changesState, !late { expectingTurnSince = nil }
        if event.kind == .turnStarted, !late { lastTurnStartedAt = event.receivedAt }
        if let reply = AgentReply.from(event) { lastReply = reply }
        setActivity(activity.apply(event, promptPending: promptPending))
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

    /// Replaces the activity; `onActivityChanged` only when what is saved moved.
    func setActivity(_ next: ThreadActivity) {
        let previous = activity
        activity = next
        refreshActivityHeadline()
        if next.turns != previous.turns || next.inTurn != previous.inTurn { turnRevision &+= 1 }
        if next.turns != previous.turns || next.lastReply != previous.lastReply
            || next.transcriptPath != previous.transcriptPath || next.inTurn != previous.inTurn {
            onActivityChanged?(self)
        }
    }

    private func refreshActivityHeadline() {
        let next = ThreadActivityHeadline.make(activity, state: displayState)
        if activityHeadline != next { activityHeadline = next }
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
        guard phase.isAlive, deliversEvents, let signal = inputTracker.feed(bytes) else { return }
        if signal == .interrupt, adapterState == .running {
            setActivity(activity.closingOpenTurn(as: .interrupted, at: .now))
        }
        guard let next = ThreadStateMachine.next(adapterState ?? .initial, onUserInput: signal,
                                                 adapterReportsTurnStart: AdapterInstaller.reportsTurnStart(profile))
        else { return }
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
        setActivity(activity.closingOpenTurn(at: .now))
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
