import Foundation
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

    /// ⌘D, ⇧⌘B, a task's menu, a notification: open the section — never close it — and give it the keyboard.
    func revealSection(_ section: InspectorSection) {
        inspectorShown = true
        // A request nothing can take now must not wait: it would take the keyboard from the terminal whenever the
        // section next appears.
        guard isSectionAvailable(section) else { return }
        setSection(section, open: true)
        inspector.requestFocus(section)
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
