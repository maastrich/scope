import AppKit
import Foundation
import ScopeAdapters
import ScopeCore
import ScopeDrivers
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
    /// OSC 0/2 title.
    private(set) var terminalTitle: String?
    /// OSC 7 directory, decoded from its `file://` form.
    private(set) var reportedDirectory: String?
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var lastError: LaunchError?
    private(set) var hasLaidOut = false

    @ObservationIgnored private var pendingPlan: LaunchPlan?
    @ObservationIgnored private var inputTracker = TerminalInputTracker()
    @ObservationIgnored private var layoutFallback: Task<Void, Never>?

    /// Called on every record change so `AppModel` persists it.
    @ObservationIgnored var onRecordChanged: (@MainActor (ThreadRecord) -> Void)?
    /// Called when the process exits (after the record was updated).
    @ObservationIgnored var onExit: (@MainActor (ThreadSession, ExitStatus) -> Void)?

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
        if record.launchCount > 0 {
            printNotice("relaunched \(Date.now.formatted(date: .omitted, time: .standard))")
        }
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
        inputTracker = TerminalInputTracker()
        phase = .alive(pid: view.process.shellPid, since: .now)
        record.lastLaunchedAt = .now
        record.launchCount += 1
        record.lastExit = nil
        record.lastState = .initial
        onRecordChanged?(record)
        Log.threads.info("thread \(self.id.rawValue, privacy: .public) started pid \(view.process.shellPid): \(plan.displayCommand, privacy: .public)")
    }

    // MARK: Stop

    /// SIGHUP now (what Terminal.app does when its window closes), SIGKILL if the same pid is still alive
    /// after `seconds`. The exit path then runs normally through `processTerminated`.
    func stop(escalateAfter seconds: Double = 3) {
        guard let view = _terminalView, view.process.running else { return }
        let pid = view.process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let view = self._terminalView, view.process.running, view.process.shellPid == pid else { return }
            Log.threads.warning("thread \(self.id.rawValue, privacy: .public): pid \(pid) ignored SIGHUP, sending SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    // MARK: Input / output

    func send(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Types `text`, then presses ↩ on its own a moment later. Sent in one write, the ↩ lands in the same read as
    /// the text and a TUI such as Claude Code takes the whole chunk for a paste: the ↩ becomes a newline in the
    /// prompt and nothing is submitted.
    func submit(_ text: String) {
        guard !text.isEmpty else {
            send("\r")
            return
        }
        send(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.submitDelay) { [weak self] in
            guard let self, self.phase.isAlive else { return }
            self.send("\r")
        }
    }

    /// Long enough for the child to have read the text before the ↩ arrives.
    static let submitDelay: TimeInterval = 0.15

    /// Feeds a divider line into the emulator (not to the child).
    func printNotice(_ text: String) {
        terminalView.feed(text: "\r\n\u{1b}[2m── \(text) ──\u{1b}[0m\r\n")
    }

    // MARK: Adapter

    func resetAdapterState() {
        adapterState = nil
    }

    func apply(_ event: AdapterEvent) {
        guard phase.isAlive else { return }
        let next = ThreadStateMachine.next(adapterState ?? .initial, on: event)
        adapterState = next
        lastFailure = next == .failed ? (event.payload[HookEvent.errorKey] ?? lastFailure) : nil
        record.lastState = next
        if let session = event.payload["session_id"] ?? event.payload["resume_id"], !session.isEmpty {
            record.resumeID = session
        }
        onRecordChanged?(record)
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
        guard let next = ThreadStateMachine.next(adapterState ?? .initial, onUserInput: signal,
                                                 adapterReportsTurnStart: AdapterInstaller.reportsTurnStart(profile))
        else { return }
        setAdapterState(next)
    }

    private func setAdapterState(_ state: ThreadState) {
        adapterState = state
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
        record.lastExit = status
        record.lastState = .exited
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
