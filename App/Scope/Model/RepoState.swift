import Foundation
import ScopeCore
import ScopeGit

/// One discovered repository of a scope: what the sidebar row shows, refreshed through the shared
/// `GitClientRegistry`. Refreshes coalesce: one in flight, at most one queued behind it.
@MainActor
@Observable
final class RepoState: Identifiable {
    /// Relative path from the scope root (`""` for a repo-scope root).
    let id: String
    let url: URL
    private(set) var discovered: DiscoveredRepo
    private(set) var facts: RepoFacts?
    private(set) var isRefreshing = false

    @ObservationIgnored private let git: GitClientRegistry
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var queued = false

    init(discovered: DiscoveredRepo, git: GitClientRegistry) {
        self.id = discovered.relativePath
        self.url = discovered.url
        self.discovered = discovered
        self.git = git
    }

    /// `owner/repo` from the remote when known, else the folder name.
    var displayName: String {
        facts?.remote?.fullName ?? url.lastPathComponent
    }

    /// Current branch, `detached` when HEAD is detached, `nil` before the first load.
    var branchLabel: String? {
        guard let facts else { return nil }
        if let branch = facts.currentBranch { return branch }
        return facts.isDetached ? "detached" : nil
    }

    var isDirty: Bool { facts?.isDirty ?? false }

    /// A rescan found the same repo again (its kind may have changed, e.g. clone → worktree).
    func update(discovered: DiscoveredRepo) {
        self.discovered = discovered
    }

    /// Reloads the facts off the main actor. Coalesced.
    func refreshFacts() {
        if inFlight {
            queued = true
            return
        }
        inFlight = true
        let url = url
        let git = git
        let spinner = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.isRefreshing = true
        }
        Task { [weak self] in
            let client = await git.client(for: url)
            let facts = await RepoFacts.load(for: url, using: client)
            spinner.cancel()
            guard let self else { return }
            self.facts = facts
            self.isRefreshing = false
            self.inFlight = false
            if self.queued {
                self.queued = false
                self.refreshFacts()
            }
        }
    }
}
