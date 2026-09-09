import AppKit
import Foundation
import Observation
import ScopeCore
import ScopeGit
import ScopeTasks

/// What the command palette shows: everything, or the Files section alone (⌘P file finder).
enum PaletteMode: Equatable {
    case all
    case files
}

/// One root the file finder lists: a base checkout or a task sandbox.
struct FileRoot: Identifiable, Hashable {
    enum Kind: Hashable {
        case base(scope: ScopeID, repo: String)
        case sandbox(task: TaskID, repo: String)
    }

    let kind: Kind
    let url: URL
    let label: String

    var id: URL { url }
}

/// State of the search & discovery surfaces that `AppModel` cannot hold itself (it is extended, not edited):
/// the sidebar filter, the palette mode, the per-repo file lists of the file finder and the palette's recents.
@MainActor
@Observable
final class SearchUIState {
    static let shared = SearchUIState()

    /// The sidebar filter field; empty shows every row.
    var sidebarFilter = ""
    /// Incremented by ⌥⌘F; the sidebar field focuses itself on change.
    var sidebarFilterFocusTick = 0
    var paletteMode: PaletteMode = .all

    /// `git ls-files` of one root, with lowercased characters ready for fuzzy matching.
    struct FileList {
        let paths: [String]
        let lowered: [[Character]]
        let loadedAt: Date
        /// `TaskState.changeTick` when a sandbox was listed; `-1` for base checkouts.
        let tick: Int
    }

    private(set) var files: [URL: FileList] = [:]
    @ObservationIgnored private var loading: Set<URL> = []
    /// Ids of the last chosen palette items, most recent first.
    private(set) var recents: [String]

    static let recentsKey = "palette.recents"
    static let recentsLimit = 20
    /// Base checkouts are relisted when older than this (sandboxes follow their FSEvents `changeTick`).
    static let baseRefreshInterval: TimeInterval = 30

    init(defaults: UserDefaults = .standard) {
        recents = defaults.stringArray(forKey: Self.recentsKey) ?? []
    }

    func noteChosen(_ id: String, defaults: UserDefaults = .standard) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > Self.recentsLimit { recents.removeLast(recents.count - Self.recentsLimit) }
        defaults.set(recents, forKey: Self.recentsKey)
    }

    /// Position in the recents (0 = most recent), `nil` when never chosen.
    func recency(of id: String) -> Int? {
        recents.firstIndex(of: id)
    }

    /// Lists `root` when unknown or stale. Concurrent calls for the same root coalesce.
    func refreshFiles(root: FileRoot, tick: Int, git: GitClientRegistry) {
        if let cached = files[root.url] {
            let stale = tick >= 0 ? cached.tick != tick : Date.now.timeIntervalSince(cached.loadedAt) > Self.baseRefreshInterval
            guard stale else { return }
        }
        guard !loading.contains(root.url) else { return }
        loading.insert(root.url)
        let url = root.url
        Task {
            let paths = await Task.detached(priority: .userInitiated) { () -> [String] in
                let client = await git.client(for: url)
                return (try? await client.fileTree().filePaths) ?? []
            }.value
            let sorted = paths.sorted()
            files[url] = FileList(paths: sorted, lowered: sorted.map { Array($0.lowercased()) }, loadedAt: .now, tick: tick)
            loading.remove(url)
        }
    }
}

extension AppModel {
    var searchUI: SearchUIState { .shared }

    /// Opens the palette in `mode` (⌘K everything, ⌘P files).
    func showPalette(mode: PaletteMode) {
        searchUI.paletteMode = mode
        if paletteShown, mode == .all { paletteShown = false } else { paletteShown = true }
    }

    /// ⌥⌘F: focuses the sidebar filter field.
    func focusSidebarFilter() {
        searchUI.sidebarFilterFocusTick += 1
    }

    // MARK: File finder

    /// The roots the Files section lists: the current task's sandboxes, else the Base panel's repo.
    var fileRoots: [FileRoot] {
        if let task = currentTask {
            return task.activeRepos.map { repo in
                FileRoot(kind: .sandbox(task: task.id, repo: repo.repoRelativePath), url: repo.sandboxURL,
                         label: "\(repo.isScopeRoot ? task.record.scopeName : repo.name) · \(task.name)")
            }
        }
        guard let scope = currentScope, let repo = baseRepo else { return [] }
        return [FileRoot(kind: .base(scope: scope.id, repo: repo.id), url: repo.url, label: "\(repo.shortName) · base")]
    }

    /// Lists (or relists) every root of `fileRoots`.
    func refreshFileLists() {
        for root in fileRoots {
            let tick: Int
            if case .sandbox(let taskID, _) = root.kind { tick = task(taskID)?.changeTick ?? 0 } else { tick = -1 }
            searchUI.refreshFiles(root: root, tick: tick, git: env.git)
        }
    }

    /// Opens a file of the finder: base files in the Base viewer, sandbox files in the editor.
    func openFile(_ path: String, in root: FileRoot) {
        switch root.kind {
        case .base(let scopeID, let repoID):
            guard let scope = scope(scopeID), let repo = scope.repo(relativePath: repoID) else { return }
            showBase(repo: repo, in: scope)
            base.show(repo: repo)
            base.section = .files
            base.open(path: path)
        case .sandbox:
            openInEditor(path: root.url.path, file: root.url.appending(path: path).path)
        }
    }

    // MARK: Rename

    /// Sets a thread's title: the session updates its record (sidebar row, tab and palette follow at once)
    /// and persists it through the record-save path.
    func renameThread(_ id: ThreadID, to title: String) {
        session(id)?.setTitle(title)
    }

    /// "Rename Thread…": an alert with a text field prefilled with the current title.
    func promptRenameThread(_ id: ThreadID) {
        guard let session = session(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Thread"
        alert.informativeText = "The title is shown in the sidebar and the command palette."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: session.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "Title"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameThread(id, to: field.stringValue)
    }
}
