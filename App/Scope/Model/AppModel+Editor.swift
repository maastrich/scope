import AppKit
import ScopeCore
import ScopeDrivers
import ScopeTasks

/// "Open in Editor" (spec §4.8): which checkout a gesture means, and how the editor is started on it.
extension AppModel {
    // MARK: Targets

    /// ⌘E: the checkout the thread works in (its sandbox for a task thread, its repository otherwise), else
    /// the selected repo, the selected task, or the scope root.
    func editorTarget(thread id: ThreadID?) -> EditorTarget? {
        if let id, let session = session(id) {
            return editorTarget(of: session)
        }
        switch selection {
        case .repo(let scopeID, let relativePath):
            guard let scope = scope(scopeID) else { return nil }
            return EditorTarget(folder: scope.repo(relativePath: relativePath)?.url.path
                                ?? scope.url.appending(path: relativePath).path)
        case .task(let id):
            return task(id).map(editorTarget(of:))
        case .scope, .thread, nil:
            return currentScope.map { EditorTarget(folder: $0.url.path) }
        }
    }

    /// The checkout a thread is in, never the subfolder it wandered into: the editor shows a whole project, and
    /// only finds the window it already has for it when handed the same root every time. The driver's last
    /// touched file comes first — in a task of several repositories it is what tells them apart — then the
    /// shell's directory. A task thread sitting at the task root gets the whole task.
    private func editorTarget(of session: ThreadSession) -> EditorTarget {
        let directories = [session.agentDirectory, session.reportedDirectory, session.record.cwd].compactMap { $0 }
        if let task = task(of: session) {
            for directory in directories {
                if let repo = task.record.sandbox(containing: directory) { return EditorTarget(folder: repo.sandboxPath) }
            }
            return editorTarget(of: task)
        }
        let repos = scope(session.record.scopeID)?.repos ?? []
        for directory in directories {
            let path = URL(fileURLWithPath: directory).standardizedFileURL.path
            let enclosing = repos
                .map(\.url.standardizedFileURL.path)
                .filter { path == $0 || path.hasPrefix($0 + "/") }
                .max { $0.count < $1.count }
            if let enclosing { return EditorTarget(folder: enclosing) }
        }
        return EditorTarget(folder: session.reportedDirectory ?? session.record.cwd)
    }

    /// ⇧⌘E: every sandbox of the task, with the `.code-workspace` for the editors that read one.
    func editorTarget(of task: TaskState) -> EditorTarget {
        let workspace = task.record.workspaceURL.path
        return EditorTarget(taskRoot: task.record.threadCwd.path,
                            sandboxes: task.activeRepos.map(\.sandboxPath),
                            workspace: FileManager.default.fileExists(atPath: workspace) ? workspace : nil)
    }

    /// What ⌘E would open right now (for ⌥-click copy).
    var currentEditorPath: String? {
        editorTarget(thread: selectedThreadID)?.copiedPath
    }

    // MARK: Gestures

    func openInEditor(thread id: ThreadID?) {
        guard let target = editorTarget(thread: id) else { return }
        openInEditor(target)
    }

    func openTaskInEditor(_ task: TaskState) {
        openInEditor(editorTarget(of: task))
    }

    /// Every "Open in Editor" affordance: ⌥-click copies the path instead (spec §7).
    func openInEditorOrCopy(path: String, file: String? = nil, line: Int? = nil) {
        let target = EditorTarget(folder: path, file: file, line: line)
        if NSEvent.modifierFlags.contains(.option) {
            Pasteboard.copy(target.copiedPath)
            return
        }
        openInEditor(target)
    }

    func openInEditor(path: String, file: String? = nil, line: Int? = nil) {
        openInEditor(EditorTarget(folder: path, file: file, line: line))
    }

    // MARK: Launch

    /// The known editors installed on this Mac, one that is running first: the editor already open is the one
    /// the user works in.
    var installedEditors: [KnownEditor] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let installed = KnownEditor.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
        return installed.filter { running.contains($0.bundleID) } + installed.filter { !running.contains($0.bundleID) }
    }

    /// The configured editor, else the first installed one — saved, so the next gesture opens the same editor
    /// whichever happens to be running then.
    private func editorForLaunch() -> EditorTemplate? {
        if let editor = config.preferences.editor { return editor }
        guard let detected = installedEditors.first else { return nil }
        updatePreferences { $0.editor = detected.template }
        return detected.template
    }

    func openInEditor(_ target: EditorTarget) {
        guard let editor = editorForLaunch() else {
            problems.warn("No editor found",
                          detail: "None of Cursor, VS Code, Zed, Sublime Text, IntelliJ or Nova is installed. Enter your editor's command in Settings.",
                          actions: [ProblemAction(title: "Open Settings", kind: .openSettings)])
            return
        }
        switch shellStatus {
        case .ready(let environment), .fallback(let environment):
            launch(editor, on: target, searchPATH: environment.path)
        case .probing:
            // In the first seconds the login-shell PATH is not known yet, and the app's own one (launchd's) has
            // neither Homebrew nor /usr/local/bin: wait for the probe rather than fail on it.
            Task { [env] in
                let environment = await env.shell.environment()
                launch(editor, on: target, searchPATH: environment.path)
            }
        }
    }

    private func launch(_ editor: EditorTemplate, on target: EditorTarget, searchPATH: String) {
        do {
            try editor.launch(target, searchPATH: searchPATH) {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }
        } catch {
            problems.error("Could not open the editor", detail: String(describing: error),
                           actions: [ProblemAction(title: "Open Settings", kind: .openSettings)])
        }
    }
}
