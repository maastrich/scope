import AppKit
import Foundation
import ScopeCore
import ScopeTasks

/// The task's Browser pane (spec §7): a web view of the task's dev servers in the reading column, on the user's
/// data store of the scope. Opened by ⌃⇧B, the pane strip, the Task menu and the palette; port chips and ⌘-clicks
/// on links reach it through `BrowserRoute`; closed with the task.
extension AppModel {
    var currentBrowserTabs: [BrowserSession] {
        currentTask.map { browser.sessions(of: $0.id) } ?? []
    }

    var currentBrowserTab: BrowserSession? {
        currentTask.flatMap { browser.selected(of: $0.id) }
    }

    /// ⌃⇧B: the pane comes up — on the task's first server when it has no tab yet — or goes away when it is shown.
    func toggleBrowser() {
        guard let task = currentTask, !task.isArchived else { return }
        if shownViewer == .browser {
            inspector.closeViewer()
            AppDelegate.refocusTerminal()
            return
        }
        if browser.sessions(of: task.id).isEmpty {
            newBrowserTab(in: task)
        } else {
            inspector.show(.browser)
        }
        Usage.click("task.browser.toggle", label: "Toggle the task's browser pane")
    }

    /// `+`, or the first ⌃⇧B: a tab on the first port something listens on, else `SCOPE_PORT`, address bar focused.
    func newBrowserTab(in task: TaskState) {
        let port = task.listeningPorts.first ?? task.record.portBlock?.base
        let session = openBrowserTab(port.map(PortBlock.url(for:)), in: task)
        session?.focusAddress()
    }

    /// `url` in `task`'s pane: the tab already on its server navigates there, or a new tab opens. The pane is shown.
    @discardableResult
    func openInBrowser(_ url: URL, in task: TaskState) -> BrowserSession? {
        guard !task.isArchived else { return nil }
        if let existing = browser.session(of: task.id, serving: url) {
            if existing.url != url { existing.load(url) }
            browser.select(existing.id)
            inspector.show(.browser)
            return existing
        }
        return openBrowserTab(url, in: task)
    }

    @discardableResult
    private func openBrowserTab(_ url: URL?, in task: TaskState) -> BrowserSession? {
        guard !task.isArchived else { return nil }
        let session = BrowserSession(taskID: task.id, storeID: BrowserStoreID.user(home: env.home, scope: task.scopeID.rawValue),
                                     url: url)
        session.onOpenWindow = { [weak self] session, url in
            guard let self, let task = self.task(session.taskID) else { return }
            self.openBrowserTab(url, in: task)
        }
        browser.add(session)
        inspector.show(.browser)
        return session
    }

    func selectBrowserTab(_ id: String) {
        browser.select(id)
    }

    func closeBrowserTab(_ id: String) {
        guard let session = browser.remove(id) else { return }
        dismissBrowserPaneIfEmpty(task: session.taskID)
    }

    /// Archive, close: every tab of the task goes, and its web views with it.
    func closeBrowserTabs(of taskID: TaskID) {
        browser.removeAll(of: taskID)
        dismissBrowserPaneIfEmpty(task: taskID)
        removeAgentBrowserData(of: taskID)
    }

    /// The page of the shown tab, in the system browser.
    func openBrowserTabInSystem(_ session: BrowserSession) {
        guard let url = session.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Routing

    /// A web link clicked in a terminal, rendered Markdown or a chip of `task`: the pane or the system browser,
    /// as `BrowserRoute` says with the preference and ⌥. `false` when `link` is not a web URL.
    @discardableResult
    func openWebLink(_ link: String, task taskState: TaskState?) -> Bool {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), BrowserRoute.isWeb(url) else {
            return false
        }
        let alternate = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        let usable = taskState.flatMap { $0.isArchived ? nil : $0 }
        switch BrowserRoute.destination(for: url, block: usable?.record.portBlock, preference: config.preferences.openWebLinks,
                                        hasTask: usable != nil, alternate: alternate) {
        case .pane:
            guard let usable else { return false }
            if currentTask?.id != usable.id { selectLinkedTask(usable) }
            openInBrowser(url, in: usable)
            Usage.click("task.browser.open-link", label: "Open a web link in the browser pane")
        case .system:
            NSWorkspace.shared.open(url)
        }
        return true
    }

    /// The last task's tab is gone — or the task itself: back to what the pane covered, else nothing.
    private func dismissBrowserPaneIfEmpty(task taskID: TaskID) {
        guard inspector.viewer == .browser, browser.sessions(of: taskID).isEmpty,
              currentTask == nil || currentTask?.id == taskID else { return }
        if let previous = inspector.previousViewer, isShowable(previous) {
            inspector.goBack()
        } else {
            inspector.closeViewer()
        }
    }
}
