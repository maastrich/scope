import AppKit
import Foundation
import ScopeCore
import ScopeDrivers
import ScopeTasks
import SwiftTerm

/// One shell of a task's shell pane: the terminal view it owns for its whole life and the login shell inside.
/// A `ThreadSession` without the thread — no record, no adapter, no sidebar row; it lives as long as its tab,
/// and its tab lives as long as the task.
@MainActor
@Observable
final class TaskShellSession: Identifiable {
    let id: TaskShellID
    let taskID: TaskID
    /// The login shell, for the tab's title before the shell says anything.
    let shell: String
    let cwd: String

    /// Created on first access, like a thread's, with the palette of the current appearance.
    @ObservationIgnored private var _terminalView: ScopeTerminalView?
    var terminalView: ScopeTerminalView {
        if let _terminalView { return _terminalView }
        let view = ScopeTerminalView(frame: TerminalAppearance.initialFrame,
                                     font: TerminalAppearance.font,
                                     options: TerminalAppearance.options)
        TerminalAppearance.apply(to: view)
        view.processDelegate = bridge
        view.onOpenLink = { [weak self] link in
            guard let self else { return false }
            return self.onOpenLink?(self, link) ?? false
        }
        _terminalView = view
        return view
    }

    @ObservationIgnored private let bridge = TaskShellBridge()

    private(set) var isAlive = false
    /// The environment the shell was started with, for the footer; empty until the plan is known.
    private(set) var environment: [String: String] = [:]
    /// OSC 0/2 title, as the prompt sets it.
    private(set) var reportedTitle: String?
    /// OSC 7 directory.
    private(set) var reportedDirectory: String?
    private(set) var hasLaidOut = false
    @ObservationIgnored private var pendingPlan: LaunchPlan?
    @ObservationIgnored private var layoutFallback: Task<Void, Never>?

    /// The shell exited, however: the tab goes with it.
    @ObservationIgnored var onExit: (@MainActor (TaskShellSession) -> Void)?
    /// A link clicked in the terminal; `true` when it was shown in the app.
    @ObservationIgnored var onOpenLink: (@MainActor (TaskShellSession, String) -> Bool)?

    init(taskID: TaskID, shell: String, cwd: String) {
        self.id = TaskShellID()
        self.taskID = taskID
        self.shell = shell
        self.cwd = cwd
        bridge.session = self
    }

    /// What the tab says (`TaskShell.tabTitle`).
    var title: String { TaskShell.tabTitle(reported: reportedTitle, shell: shell, cwd: cwd) }

    var pid: pid_t? {
        guard let view = _terminalView, view.process.running else { return nil }
        return view.process.shellPid
    }

    // MARK: Launch

    /// Starts now when the view has been laid out at least once, otherwise on the first layout (so the shell is
    /// forked with the real cols × rows) or after `ThreadSession.layoutFallbackDelay` on the default frame.
    func launch(_ plan: LaunchPlan) {
        environment = plan.environment
        if hasLaidOut {
            start(plan)
            return
        }
        pendingPlan = plan
        layoutFallback?.cancel()
        layoutFallback = Task { [weak self] in
            try? await Task.sleep(for: ThreadSession.layoutFallbackDelay)
            guard !Task.isCancelled, let self, let plan = self.pendingPlan else { return }
            self.pendingPlan = nil
            self.start(plan)
        }
    }

    /// The shell could not be planned: said in the terminal, where the user is looking, and the tab closes itself.
    func fail(_ error: LaunchError) {
        pendingPlan = nil
        layoutFallback?.cancel()
        terminalView.feed(text: "\u{1b}[31m\(error.title)\u{1b}[0m\r\n\(error.detail.replacingOccurrences(of: "\n", with: "\r\n"))\r\n")
        Log.threads.error("task shell \(self.id.rawValue, privacy: .public): \(error.title, privacy: .public)")
    }

    func viewDidLayout() {
        hasLaidOut = true
        if let plan = pendingPlan {
            pendingPlan = nil
            start(plan)
        }
    }

    private func start(_ plan: LaunchPlan) {
        layoutFallback?.cancel()
        layoutFallback = nil
        pendingPlan = nil
        let view = terminalView
        guard !view.process.running else { return }
        view.startProcess(executable: plan.executable, args: plan.arguments, environment: plan.envp,
                          execName: plan.argv0, currentDirectory: plan.cwd)
        guard view.process.running else {
            fail(.forkFailed)
            return
        }
        isAlive = true
        Log.threads.info("task shell \(self.id.rawValue, privacy: .public) started pid \(view.process.shellPid) in \(plan.cwd, privacy: .public)")
    }

    // MARK: Stop

    /// SIGHUP to the shell and its group, SIGKILL after `seconds` if the same pid is still there — a closed tab
    /// or a closed task takes a `swift test` still running with it.
    func stop(escalateAfter seconds: Double = 3) {
        guard let view = _terminalView, view.process.running else { return }
        let pid = view.process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGHUP)
        if getpgid(pid) == pid { kill(-pid, SIGHUP) }
        // The view, not the session: a closed tab's session may be gone by then, the shell must not be.
        let id = id
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard view.process.running, view.process.shellPid == pid else { return }
            Log.threads.warning("task shell \(id.rawValue, privacy: .public): pid \(pid) ignored SIGHUP, sending SIGKILL")
            kill(pid, SIGKILL)
            if getpgid(pid) == pid { kill(-pid, SIGKILL) }
        }
    }

    // MARK: Terminal reports

    fileprivate func handleTitle(_ title: String) {
        let next = title.isEmpty ? nil : title
        if reportedTitle != next { reportedTitle = next }
    }

    fileprivate func handleDirectory(_ directory: String?) {
        reportedDirectory = directory.flatMap { URL(string: $0)?.path }
    }

    fileprivate func handleExit() {
        guard isAlive else { return }
        isAlive = false
        onExit?(self)
    }
}

/// SwiftTerm's delegate for a task shell, isolated like `TerminalBridge` (SwiftTerm always calls on the main
/// thread) and weak toward the session, which retains it.
@MainActor
private final class TaskShellBridge: NSObject, @MainActor LocalProcessTerminalViewDelegate {
    weak var session: TaskShellSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        session?.handleTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        session?.handleDirectory(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        session?.handleExit()
    }
}
