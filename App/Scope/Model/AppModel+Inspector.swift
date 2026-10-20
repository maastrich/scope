import Foundation
import ScopeAdapters
import ScopeCore
import ScopeTasks

extension AppModel {
    var hasInspectorTask: Bool { currentTask != nil }

    func isSectionOpen(_ section: InspectorSection) -> Bool {
        inspector.sections.isOpen(section, hasTask: hasInspectorTask)
    }

    /// A section has something to show: a task for the task's sections, a repository for the base's.
    func isSectionAvailable(_ section: InspectorSection) -> Bool {
        section.needsTask ? currentTask != nil : currentScope != nil && baseSubject() != nil
    }

    func setSection(_ section: InspectorSection, open: Bool) {
        guard isSectionOpen(section) != open else { return }
        inspector.sections.setOpen(section, open, hasTask: hasInspectorTask)
        // Opening the search is asking to type in it.
        if open, section == .search { inspector.requestFocus(.search) }
        persistUIState()
    }

    func toggleSection(_ section: InspectorSection) {
        setSection(section, open: !isSectionOpen(section))
    }

    func isSectionVisible(_ section: InspectorSection) -> Bool {
        inspector.sections.isVisible(section)
    }

    /// The Cards menu: a card taken out of the column, or put back as it was left.
    func setSection(_ section: InspectorSection, visible: Bool) {
        guard isSectionVisible(section) != visible else { return }
        inspector.sections.setVisible(section, visible)
        persistUIState()
    }

    enum CardPlacementChoice { case automatic, pinned, hidden }

    /// The Cards menu: a card left to come up by itself, pinned to Overview, or taken out of the column.
    func setCard(_ section: InspectorSection, _ choice: CardPlacementChoice) {
        switch choice {
        case .automatic:
            inspector.sections.setVisible(section, true)
            inspector.sections.setPinned(section, false)
        case .pinned:
            inspector.sections.setPinned(section, true)
        case .hidden:
            inspector.sections.setVisible(section, false)
        }
        persistUIState()
    }

    func resetSections() {
        inspector.sections.reset()
        persistUIState()
    }

    /// ⌘D, ⇧⌘B, a task's menu, a notification: open the section — never close it —, turn to the page it is on and
    /// give it the keyboard.
    func revealSection(_ section: InspectorSection) {
        inspectorShown = true
        // A request nothing can take now must not wait: it would take the keyboard from the terminal whenever the
        // section next appears.
        guard isSectionAvailable(section) else { return }
        // A hidden card asked for by name comes back: ⌘D means the changes, wherever the column had them.
        setSection(section, visible: true)
        setSection(section, open: true)
        if let page = inspectorPlacement().page(of: section) { showInspectorPage(page) }
        inspector.requestFocus(section)
    }

    // MARK: Pages

    /// Overview or Details. Opening Details clears its dot.
    func showInspectorPage(_ page: InspectorPage) {
        inspector.page = page
        if page == .details { inspector.detailsHasNews = false }
    }

    /// ⇧⌘D and the Details button: one page, then the other.
    func toggleInspectorDetails() {
        inspectorShown = true
        showInspectorPage(inspector.page == .details ? .overview : .details)
    }

    /// Where every card of the current subject goes now (`InspectorPlacement`).
    func inspectorPlacement(now: Date = .now) -> InspectorPlacement.Result {
        let task = currentTask
        return InspectorPlacement.place(sections: inspector.sections, hasTask: task != nil,
                                        signals: task.map { inspectorSignals(for: $0, now: now) } ?? [:],
                                        retained: inspector.retainedTask == task?.id ? inspector.retained : [],
                                        now: now)
    }

    /// After a placement was drawn, or a card opened or folded: the open Overview cards are kept there (a task switch
    /// starts afresh), and a card that went down while Details was not on show lights its dot.
    func inspectorPlacementChanged(_ result: InspectorPlacement.Result) {
        let task = currentTask?.id
        let sameTask = inspector.retainedTask == task
        if sameTask, let last = inspector.lastPlacement, inspector.page != .details,
           !InspectorPlacement.demoted(from: last, to: result).isEmpty {
            inspector.detailsHasNews = true
        }
        if !sameTask { inspector.detailsHasNews = false }
        let open = Set(InspectorSection.allCases.filter(isSectionOpen))
        inspector.retained = InspectorPlacement.retained(previous: sameTask ? inspector.retained : [],
                                                         overview: result.overview, open: open)
        inspector.retainedTask = task
        inspector.lastPlacement = result
    }

    /// What each event card of `task` has to say at `now`. Sub-agents and background commands count while they run,
    /// and linger from the last one's end; the rest count while they hold anything. Checkpoints alone are not an
    /// artifact: every turn leaves one.
    func inspectorSignals(for task: TaskState, now: Date) -> [InspectorSection: InspectorPlacement.Signal] {
        let threads = threads(in: task.id)
        var signals: [InspectorSection: InspectorPlacement.Signal] = [:]

        let hasPlan = threads.contains { $0.isAlive && $0.activity.plan != nil }
        signals[.plan] = .init(hasContent: hasPlan || !(task.record.mission?.milestones.isEmpty ?? true))

        signals[.delta] = .init(hasContent: changedFileCount(of: task) > 0)

        signals[.pullRequest] = .init(hasContent: !pullRequestFacts(for: task).isEmpty || task.record.primaryPullRequest != nil)

        let agents = threads.flatMap { session in session.claude.subagents.agents.map { (session.isAlive, $0) } }
        signals[.subagents] = .init(hasContent: agents.contains { alive, agent in agent.state(alive: alive).isRunning },
                                    endedAt: agents.compactMap(\.1.endedAt).max())

        let work = threads.map(\.claude.background)
        let busy = work.contains { !$0.running(at: now).isEmpty || $0.wakeup != nil || !$0.crons.isEmpty }
        signals[.background] = .init(hasContent: busy, endedAt: work.flatMap(\.tasks).compactMap(\.endedAt).max())

        let produced = task.artifacts.map { !$0.producedNothing } ?? false
        signals[.artifacts] = .init(hasContent: produced || (task.artifacts != nil && deliverable(of: task) != nil))
        return signals
    }

    /// The task's changed files, the Changes card's count when it is loaded for it, the sidebar summaries otherwise.
    func changedFileCount(of task: TaskState) -> Int {
        if delta.taskID == task.id, delta.hasLoaded, delta.mode == .task {
            return delta.summary.files
        }
        return task.activeSandboxes.compactMap { task.summary(for: $0) }.reduce(0) { $0 + $1.files }
    }

    /// What the Artifacts card reads changes with a turn opening or closing (`turnRevision`), the sandbox
    /// (`changeTick`) and the checkpoints; the inspector reloads it on any of them, whichever page the card is on.
    func artifactsRefreshKey(_ task: TaskState) -> String {
        let turns = threads(in: task.id).map { "\($0.id.rawValue):\($0.turnRevision)" }.joined(separator: ",")
        return "\(task.id.rawValue)|\(task.changeTick)|\(task.checkpoints.count)|\(turns)"
    }

    /// Selects a changed file and shows its diff in the viewer.
    func showDiff(_ ref: DeltaFileRef?) {
        delta.selectedFile = ref
        delta.focusedHunk = nil
        if ref != nil {
            inspector.show(.diff)
            if !Usage.attributing, let input = Usage.currentInput {
                Usage.register("inspector.delta.open-file", label: "Open a changed file")
                Usage.record(.click, "inspector.delta.open-file", source: input)
            }
        }
    }

    /// The viewer asked for, if it still has something to show: a diff needs the selected file of the selected task in
    /// a mode that has files, a file needs the base viewer to hold one. `nil` keeps the viewer column off screen.
    var shownViewer: InspectorViewer? {
        guard let viewer = inspector.viewer, isShowable(viewer) else { return nil }
        return viewer
    }

    func isShowable(_ viewer: InspectorViewer) -> Bool {
        switch viewer {
        case .diff:
            guard let task = currentTask, delta.taskID == task.id, delta.mode != .baseVsOrigin,
                  let ref = delta.selectedFile else { return false }
            return delta.file(ref) != nil && delta.taskRepo(ref.repo) != nil
        case .file:
            return base.content != nil
        case .path:
            return inspector.pathPreview != nil
        case .reading:
            return inspector.reading != nil
        case .shell:
            return currentTask.map { !taskShells.sessions(of: $0.id).isEmpty } ?? false
        case .browser:
            return currentTask.map { !browser.sessions(of: $0.id).isEmpty } ?? false
        }
    }

    // MARK: Links from the terminal

    /// A link clicked in `session`'s terminal: a file it names opens in the viewer column — the task's copy while the
    /// thread belongs to a task, the base checkout otherwise, the file itself when it lies elsewhere. `false` leaves
    /// the link to the system (a web URL, a path that names nothing on disk).
    func openFileLink(_ link: String, from session: ThreadSession) -> Bool {
        Usage.click("thread.open-link", label: "⌘-click a link in the terminal")
        let directory = session.agentDirectory ?? session.reportedDirectory ?? session.record.cwd
        return openFileLink(link, scope: session.record.scopeID,
                            task: session.record.taskID.flatMap { TaskID(rawValue: $0) }.flatMap(task), directory: directory)
    }

    /// The same, for a link read outside a terminal (the reading column): the task's sandboxes when it has any,
    /// the scope's base checkouts, relative paths from `directory`.
    func openFileLink(_ link: String, scope scopeID: ScopeID, task taskState: TaskState?, directory: String?) -> Bool {
        guard let scope = scope(scopeID) else { return false }
        var roots: [FileLinkResolver.Root] = []
        var names: [String: String] = [:]
        if let taskState {
            for repo in taskState.activeSandboxes {
                let base = repo.isScopeRoot ? scope.url.path : scope.url.appending(path: repo.repoRelativePath).path
                roots.append(.init(name: repo.sandboxKey, sandbox: repo.sandboxPath, base: base))
                names[repo.sandboxKey] = repo.sandboxLabel(scopeName: scope.name)
            }
        }
        // The scope's other repositories, base only: a path into one of them is still worth showing.
        for repo in scope.repos where !roots.contains(where: { $0.base == repo.url.path }) {
            roots.append(.init(name: repo.id, sandbox: nil, base: repo.url.path))
            names[repo.id] = repo.shortName
        }
        guard let resolution = FileLinkResolver.resolve(link, threadDirectory: directory, roots: roots,
                                                        fileExists: { FileManager.default.fileExists(atPath: $0) }),
              !resolution.candidates.isEmpty else { return false }
        inspector.pathPreview = PathPreview(candidates: resolution.candidates, line: resolution.line, repoNames: names)
        inspector.show(.path)
        inspectorShown = true
        loadPathPreview()
        return true
    }

    /// Shows another of the files the link can mean.
    func choosePathCandidate(_ index: Int) {
        guard var preview = inspector.pathPreview, preview.candidates.indices.contains(index) else { return }
        preview.index = index
        inspector.pathPreview = preview
        loadPathPreview()
    }

    private func loadPathPreview() {
        guard var preview = inspector.pathPreview else { return }
        let path = preview.current.path
        preview.content = .loading
        inspector.pathPreview = preview
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                BaseFileContent.load(URL(fileURLWithPath: path))
            }.value
            guard var current = inspector.pathPreview, current.current.path == path else { return }
            current.content = loaded
            inspector.pathPreview = current
        }
    }
}
