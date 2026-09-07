import Foundation
import ScopeCore

/// One row of the command palette. `run` performs it; `path` is what ⌥↩ copies (editor and thread rows).
struct PaletteItem: Identifiable {
    enum Section: String, CaseIterable {
        case actions = "Actions"
        case editor = "Open in Editor"
        case threads = "Go to Thread"
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
    let run: @MainActor () -> Void
}

/// Builds the rows for the current scope / task / threads and filters them (spec §7, design §8).
@MainActor
enum PaletteModel {
    static func items(_ model: AppModel) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let scope = model.currentScope
        let task = model.currentTask

        // Actions
        if let scope {
            items.append(PaletteItem(id: "new-thread", section: .actions, icon: "terminal", label: "New Thread",
                                     hint: "in \(task?.name ?? scope.name)", shortcut: "⌘T") {
                Task { _ = await model.newThread(in: scope.id, taskID: task?.id) }
            })
            if scope.kind != .missing {
                items.append(PaletteItem(id: "new-task", section: .actions, icon: "arrow.triangle.branch", label: "New Task",
                                         hint: "in \(scope.name)", shortcut: "⌘⇧T") { model.presentNewTask(in: scope.id) })
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
                                     hint: scope.name, shortcut: "⌥⌘R") { model.refreshScope(scope.id) })
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
                                     hint: task.record.workspaceURL.lastPathComponent, shortcut: "⌘⇧E", path: workspace) {
                model.openTaskInEditor(task)
            })
        }

        // Go to Thread
        let tabs = scope.map { model.threads(in: $0.id) } ?? []
        for session in model.threads {
            let index = tabs.firstIndex { $0.id == session.id }
            let shortcut = index.flatMap { $0 < 9 ? "⌘\($0 + 1)" : nil }
            items.append(PaletteItem(id: "thread-\(session.id.rawValue)", section: .threads, icon: session.profile.icon ?? "terminal",
                                     label: session.title, hint: session.displayState.displayLabel, shortcut: shortcut,
                                     path: session.reportedDirectory ?? session.record.cwd, state: session.displayState) {
                model.selection = .thread(session.id)
                model.selectedThreadID = session.id
            })
        }

        // Scopes
        for other in model.scopes where other.id != scope?.id {
            items.append(PaletteItem(id: "scope-\(other.id.rawValue)", section: .scopes, icon: "folder", label: other.name,
                                     hint: other.url.path, path: other.url.path) { model.selection = .scope(other.id) })
        }
        return items
    }

    /// Keeps the items whose label or hint fuzzy-matches `query` (subsequence, case-insensitive), best first.
    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.compactMap { item -> (PaletteItem, Int)? in
            let labelScore = fuzzyScore(query, in: item.label)
            let hintScore = item.hint.flatMap { fuzzyScore(query, in: $0) }.map { $0 - 20 }
            guard let score = [labelScore, hintScore].compactMap({ $0 }).max() else { return nil }
            return (item, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// `nil` when `query` is not a subsequence of `text`; higher is better (prefix and contiguous runs win).
    static func fuzzyScore(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        var score = 0, qi = 0, lastMatch = -2
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += ti == lastMatch + 1 ? 10 : 1
            if ti == 0 { score += 15 }
            lastMatch = ti
            qi += 1
        }
        return qi == q.count ? score - t.count / 8 : nil
    }
}
