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
        let view = LocalProcessTerminalView(frame: TerminalAppearance.initialFrame,
                                            font: TerminalAppearance.font,
                                            options: TerminalAppearance.options)
        TerminalAppearance.apply(to: view)
        view.processDelegate = bridge
        _terminalView = view
        return view
    }

    @ObservationIgnored private let bridge = TerminalBridge()

    private(set) var phase: ProcessPhase = .notStarted
    /// State from adapter events; `nil` without an adapter (a plain shell).
    private(set) var adapterState: ThreadState?
    /// OSC 0/2 title.
    private(set) var terminalTitle: String?
    /// OSC 7 directory, decoded from its `file://` form.
    private(set) var reportedDirectory: String?
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var lastError: LaunchError?
    private(set) var hasLaidOut = false

    @ObservationIgnored private var pendingPlan: LaunchPlan?
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

    /// The sidebar / tab / pill state: alive → adapter state (or `running` without an adapter);
    /// launching → `idle`; anything else → `exited`.
    var displayState: ThreadState {
        switch phase {
        case .alive: adapterState ?? .running
        case .launching: .idle
        case .notStarted, .exited, .failed: .exited
        }
    }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let view = self._terminalView, view.process.running, view.process.shellPid == pid else { return }
            Log.threads.warning("thread \(self.id.rawValue, privacy: .public): pid \(pid) ignored SIGHUP, sending SIGKILL")
            kill(pid, SIGKILL)
        }
    }

    // MARK: Input / output

    func send(_ text: String) {
        terminalView.send(txt: text)
    }

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
