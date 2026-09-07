import AppKit
import Foundation
import ScopeCore

/// One row of the command palette. `run` performs it; `path` is what ⌥↩ copies (editor, thread and file rows).
struct PaletteItem: Identifiable {
    /// Display order of the sections.
    enum Section: String, CaseIterable {
        case actions = "Actions"
        case threads = "Go to Thread"
        case tasks = "Go to Task"
        case files = "Files"
        case editor = "Open in Editor"
        case pullRequests = "Pull Requests"
        case scopes = "Scopes"
    }

    let id: String
    let section: Section
    let icon: String
    let label: String
    var hint: String? = nil
    var shortcut: String? = nil
    var path: String? = nil
    var state: ThreadState? = nil
    /// Characters of `label` (or of `hint` when `hintMatched`) the query matched; the row bolds them.
    var matched: [Int] = []
    var hintMatched = false
    let run: @MainActor () -> Void
}

/// Builds the rows for the current scope / task / threads and ranks them (spec §7, design §8) with an
/// fzf-style scorer: subsequence with gap penalties, word-boundary and prefix bonuses, hints only from three
/// characters (last two path components for absolute paths), and a recency bonus for recently chosen rows.
@MainActor
enum PaletteModel {
    /// Files shown per mode: a handful next to the other sections, a page in the file finder.
    static let fileLimitMixed = 8
    static let fileLimitFinder = 60

    // MARK: Rows

    /// Everything the palette can show for `mode`, ranked for `query`.
    static func results(_ model: AppModel, query: String, mode: PaletteMode) -> [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let files = fileItems(model, query: query, limit: mode == .files ? fileLimitFinder : (query.isEmpty ? 0 : fileLimitMixed))
        guard mode == .all else { return files }
        return rank(items(model), query: query, recents: model.searchUI) + files
    }

    static func items(_ model: AppModel) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let scope = model.currentScope
        let task = model.currentTask
        let thread = model.currentThread

        // Actions
        if let scope {
            items.append(PaletteItem(id: "new-thread", section: .actions, icon: "terminal", label: "New Thread",
                                     hint: model.newThreadTargetDescription ?? "in \(scope.name)", shortcut: "⌘T") {
                Task { await model.newThreadInCurrentContext() }
            })
            if scope.kind != .missing {
                items.append(PaletteItem(id: "new-task", section: .actions, icon: "arrow.triangle.branch", label: "New Task",
                                         hint: "in \(scope.name)", shortcut: "⇧⌘T") { model.presentNewTask(in: scope.id) })
            }
            if let task {
                for repo in model.candidateRepos(for: task) {
                    items.append(PaletteItem(id: "add-repo-\(repo.id)", section: .actions, icon: "plus.square.on.square",
                                             label: "Add \(repo.shortName) to \(task.name)", hint: repo.id) {
                        Task { await model.addRepo(repo.id, to: task.id) }
                    })
                }
            }
            if !scope.repos.isEmpty {
                items.append(PaletteItem(id: "analyze", section: .actions, icon: "sparkles", label: "Analyze Graph", hint: scope.name) {
                    model.inspectorTab = .graph
                    model.inspectorShown = true
                    Task { await model.analyzeGraph(scope: scope, withAI: false) }
                })
            }
            items.append(PaletteItem(id: "refresh", section: .actions, icon: "arrow.clockwise", label: "Refresh Scope",
                                     hint: scope.name, shortcut: "⌘R") { model.refreshScope(scope.id) })
        }
        if let thread {
            items.append(PaletteItem(id: "close-thread", section: .actions, icon: "xmark.circle", label: "Close Thread",
                                     hint: thread.title, shortcut: "⌘W") {
                Task { _ = await model.close(thread.id, force: false) }
            })
            if thread.isAlive {
                items.append(PaletteItem(id: "stop-thread", section: .actions, icon: "stop.circle", label: "Stop Thread",
                                         hint: thread.title, shortcut: "⌘.") { model.stop(thread.id) })
            } else {
                items.append(PaletteItem(id: "relaunch-thread", section: .actions, icon: "arrow.counterclockwise.circle", label: "Relaunch Thread",
                                         hint: thread.title, shortcut: "⌥⌘R") { Task { await model.relaunch(thread.id) } })
            }
            items.append(PaletteItem(id: "rename-thread", section: .actions, icon: "pencil", label: "Rename Thread…",
                                     hint: thread.title) { model.promptRenameThread(thread.id) })
        }
        if model.canUndoCloseThread {
            items.append(PaletteItem(id: "undo-close", section: .actions, icon: "arrow.uturn.backward.circle", label: "Undo Close Thread",
                                     shortcut: "⇧⌘T") { model.undoCloseThread() })
        }
        items.append(PaletteItem(id: "declare", section: .actions, icon: "folder.badge.plus", label: "Declare a Scope…", shortcut: "⌘O") {
            Task {
                let urls = await FolderPicker.chooseFolders()
                guard !urls.isEmpty else { return }
                await model.addScopes(urls)
            }
        })
        items.append(PaletteItem(id: "inspector", section: .actions, icon: "sidebar.right", label: "Toggle Inspector", shortcut: "⌥⌘I") {
            model.inspectorShown.toggle()
        })
        items.append(PaletteItem(id: "sidebar", section: .actions, icon: "sidebar.left", label: "Toggle Sidebar", shortcut: "⌃⌘S") {
            CommandServices.toggleSidebar()
        })
        items.append(PaletteItem(id: "find-files", section: .actions, icon: "doc.text.magnifyingglass", label: "Go to File…", shortcut: "⌘P") {
            model.showPalette(mode: .files)
        })
        items.append(PaletteItem(id: "settings", section: .actions, icon: "gearshape", label: "Settings…", shortcut: "⌘,") {
            CommandServices.openSettings()
        })
        items.append(PaletteItem(id: "updates", section: .actions, icon: "arrow.down.circle", label: "Check for Updates…") {
            CommandServices.updater?.checkForUpdates()
        })
        items.append(PaletteItem(id: "shortcuts", section: .actions, icon: "keyboard", label: "Keyboard Shortcuts…", shortcut: "⌘/") {
            ShortcutsWindow.show()
        })

        // Go to Thread
        let tabs = scope.map { model.threads(in: $0.id) } ?? []
        for session in model.threads {
            let index = tabs.firstIndex { $0.id == session.id }
            let shortcut = index.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil }
            items.append(PaletteItem(id: "thread-\(session.id.rawValue)", section: .threads, icon: session.profile.icon ?? "terminal",
                                     label: model.displayTitle(for: session), hint: session.displayState.displayLabel, shortcut: shortcut,
                                     path: session.reportedDirectory ?? session.record.cwd, state: session.displayState) {
                model.selection = .thread(session.id)
                model.selectedThreadID = session.id
            })
        }

        // Go to Task
        for other in model.scopes {
            for task in model.tasks(in: other.id) {
                items.append(PaletteItem(id: "task-\(task.id.rawValue)", section: .tasks, icon: "arrow.triangle.branch",
                                         label: task.name, hint: "\(other.name) · \(task.reposCaption)", path: task.record.rootURL.path) {
                    model.switchToTask(task)
                })
            }
        }

        // Open in Editor
        if let scope {
            for repo in scope.repos {
                let path = repo.url.path
                items.append(PaletteItem(id: "editor-\(repo.id)", section: .editor, icon: "chevron.left.forwardslash.chevron.right",
                                         label: repo.displayName, hint: "base · \(repo.id.isEmpty ? "." : repo.id)", path: path) {
                    model.openInEditor(path: path)
                })
            }
        }
        if let task {
            for repo in task.activeRepos {
                let path = repo.sandboxURL.path
                items.append(PaletteItem(id: "editor-sandbox-\(repo.id)", section: .editor, icon: "chevron.left.forwardslash.chevron.right",
                                         label: "\(repo.name) · \(task.name)", hint: path, path: path) { model.openInEditor(path: path) })
            }
            let workspace = task.record.workspaceURL.path
            items.append(PaletteItem(id: "editor-task", section: .editor, icon: "rectangle.split.2x1", label: "Task \(task.record.slug)",
                                     hint: task.record.workspaceURL.lastPathComponent, shortcut: "⇧⌘E", path: workspace) {
                model.openTaskInEditor(task)
            })
        }

        // Pull Requests: the loaded open PRs of the current repo, then the PR-bound tasks of the scope ("#123").
        if let scope {
            var listed: Set<Int> = []
            if let repo = model.pullRequestsRepo, model.pullRequests.repoURL == repo.url {
                for pr in model.pullRequests.pullRequests {
                    listed.insert(pr.number)
                    let bound = model.task(forPullRequest: pr.number, repo: repo, in: scope.id)
                    items.append(PaletteItem(id: "pr-\(repo.id)-\(pr.number)", section: .pullRequests, icon: "arrow.triangle.pull",
                                             label: "#\(pr.number) \(pr.title) · \(repo.shortName)",
                                             hint: bound.map { "Switch to \($0.name)" } ?? "Open in Scope · \(pr.author)", path: pr.url.absoluteString) {
                        if let bound { model.switchToTask(bound) } else { Task { await model.openPullRequest(pr, repo: repo, in: scope) } }
                    })
                }
            }
            for task in model.tasks(in: scope.id) {
                guard let pr = task.record.pullRequest, !listed.contains(pr.number) else { continue }
                items.append(PaletteItem(id: "pr-task-\(task.id.rawValue)", section: .pullRequests, icon: "arrow.triangle.pull",
                                         label: "#\(pr.number) \(pr.title) · \(task.reposCaption)", hint: "Switch to \(task.name)",
                                         path: pr.url.absoluteString) { model.switchToTask(task) })
            }
            items.append(PaletteItem(id: "show-prs", section: .pullRequests, icon: "arrow.triangle.pull", label: "Show Pull Requests",
                                     hint: model.pullRequestsRepo?.shortName, shortcut: "⇧⌘P") { model.showPullRequests() })
        }

        // Scopes
        for other in model.scopes where other.id != scope?.id {
            items.append(PaletteItem(id: "scope-\(other.id.rawValue)", section: .scopes, icon: "folder", label: other.name,
                                     hint: other.url.path, path: other.url.path) { model.selection = .scope(other.id) })
        }
        return items
    }

    /// The Files section: fuzzy over the cached `git ls-files` of `model.fileRoots`, best `limit` rows.
    static func fileItems(_ model: AppModel, query: String, limit: Int) -> [PaletteItem] {
        guard limit > 0 else { return [] }
        let roots = model.fileRoots
        guard !roots.isEmpty else { return [] }
        let q = Array(query.lowercased())
        var scored: [(PaletteItem, Int)] = []
        for root in roots {
            guard let list = model.searchUI.files[root.url] else { continue }
            for (index, path) in list.paths.enumerated() {
                let match: FuzzyMatch
                if q.isEmpty {
                    match = FuzzyMatch(score: 0, positions: [])
                } else if let m = fuzzy(q, in: list.lowered[index]) {
                    match = m
                } else {
                    continue
                }
                let name = (path as NSString).lastPathComponent
                let id = "file-\(root.url.path)/\(path)"
                var score = match.score + (model.searchUI.recency(of: id).map { 40 - 2 * $0 } ?? 0)
                // Matches inside the file name outrank matches spread over the directories.
                let nameStart = path.count - name.count
                if match.positions.last.map({ $0 >= nameStart }) == true { score += 12 }
                let item = PaletteItem(id: id, section: .files, icon: "doc.text", label: path,
                                       hint: roots.count > 1 ? root.label : nil, path: root.url.appending(path: path).path,
                                       matched: match.positions) {
                    model.openFile(path, in: root)
                }
                scored.append((item, score))
                if q.isEmpty, scored.count >= limit { break }
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    // MARK: Ranking

    /// Keeps the items matching `query`, best first (section order is applied by the view).
    static func rank(_ items: [PaletteItem], query: String, recents: SearchUIState?) -> [PaletteItem] {
        guard !query.isEmpty else { return items }
        let q = Array(query.lowercased())
        return items.compactMap { item -> (PaletteItem, Int)? in
            var item = item
            let label = fuzzy(q, in: Array(item.label.lowercased()))
            var hint: FuzzyMatch?
            if q.count >= 3, let text = item.hint {
                hint = fuzzy(q, in: Array(hintSearchText(text).lowercased())).map { FuzzyMatch(score: $0.score - 15, positions: $0.positions) }
            }
            let best: FuzzyMatch
            switch (label, hint) {
            case (let l?, let h?): best = l.score >= h.score ? l : h
            case (let l?, nil): best = l
            case (nil, let h?): best = h
            case (nil, nil): return nil
            }
            item.hintMatched = label == nil || (hint.map { $0.score > (label?.score ?? .min) } ?? false)
            item.matched = item.hintMatched ? [] : best.positions
            let recency = recents?.recency(of: item.id).map { 40 - 2 * $0 } ?? 0
            return (item, best.score + recency)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Absolute paths are matched on their last two components only; anything else as is.
    static func hintSearchText(_ hint: String) -> String {
        guard hint.hasPrefix("/") || hint.hasPrefix("~") else { return hint }
        let parts = hint.split(separator: "/").suffix(2)
        return parts.joined(separator: "/")
    }

    struct FuzzyMatch: Equatable {
        var score: Int
        var positions: [Int]
    }

    /// fzf-style subsequence score of a lowercased `query` in lowercased `text`: `nil` when it is not a
    /// subsequence. Contiguous runs and word starts (index 0, after a separator) score high, gaps cost.
    static func fuzzy(_ query: [Character], in text: [Character]) -> FuzzyMatch? {
        guard !query.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        guard query.count <= text.count else { return nil }
        // Forward greedy pass anchored on the best start: try every occurrence of the first character.
        var best: FuzzyMatch?
        var starts: [Int] = []
        for (index, character) in text.enumerated() where character == query[0] {
            starts.append(index)
            if starts.count == 6 { break }
        }
        for start in starts {
            guard let match = greedy(query, in: text, from: start) else { continue }
            if best == nil || match.score > best!.score { best = match }
        }
        return best
    }

    private static func greedy(_ query: [Character], in text: [Character], from start: Int) -> FuzzyMatch? {
        var positions: [Int] = []
        var qi = 0
        var ti = start
        var score = 0
        var last = -2
        while qi < query.count, ti < text.count {
            if text[ti] == query[qi] {
                score += 16
                if ti == last + 1 {
                    score += 8
                } else if last >= 0 {
                    score -= 3 + min(ti - last - 1, 6)
                }
                if ti == 0 {
                    score += 24
                } else if isSeparator(text[ti - 1]) {
                    score += 16
                }
                positions.append(ti)
                last = ti
                qi += 1
            }
            ti += 1
        }
        guard qi == query.count else { return nil }
        // Slightly prefer short candidates and full-word coverage.
        score -= min(text.count / 12, 8)
        if positions.count == text.count { score += 20 }
        return FuzzyMatch(score: score, positions: positions)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == " " || character == "/" || character == "-" || character == "_" || character == "." || character == "·" || character == ":"
    }

    /// Legacy entry point kept for callers that only need a boolean-ish score (sidebar filter).
    static func fuzzyScore(_ query: String, in text: String) -> Int? {
        fuzzy(Array(query.lowercased()), in: Array(text.lowercased()))?.score
    }
}
