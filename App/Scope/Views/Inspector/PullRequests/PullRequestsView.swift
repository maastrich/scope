import SwiftUI
import ScopeGit

/// The PRs inspector panel: repo picker, header (refresh, Open on GitHub), then the open pull requests of
/// the picked base checkout. `gh` missing / not logged in / no GitHub remote each get their own empty state.
struct PullRequestsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let scope = model.currentScope, let repo = model.pullRequestsRepo {
            content(scope: scope, repo: repo)
                .task(id: repo.url) { model.pullRequests.show(repo: repo) }
                .task { await model.pullRequests.autoRefresh() }
        } else {
            ContentUnavailableView {
                Label("No repository", systemImage: "arrow.triangle.pull")
            } description: {
                Text("Select a scope with at least one repository to list its pull requests.")
            }
        }
    }

    private func content(scope: ScopeState, repo: RepoState) -> some View {
        let prs = model.pullRequests
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Repository", selection: Binding(
                    get: { prs.pickedRepo[scope.id] ?? repo.id },
                    set: { prs.pickedRepo[scope.id] = $0 }
                )) {
                    ForEach(scope.repos) { candidate in
                        Text(candidate.shortName).tag(candidate.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                countBadge
                Spacer(minLength: 0)
                if prs.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                if let url = pullsURL(repo) {
                    Button {
                        model.openOnGitHub(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open on GitHub")
                }
                Button {
                    Task { await prs.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(prs.isRefreshing || prs.gh == nil)
                .help(refreshHelp)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
            Divider()
            list(scope: scope, repo: repo)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func list(scope: ScopeState, repo: RepoState) -> some View {
        let prs = model.pullRequests
        switch prs.status {
        case .ghMissing:
            unavailable("gh is not installed", icon: "terminal",
                        text: "Scope lists pull requests through the GitHub CLI.", command: "brew install gh")
        case .notAuthenticated(let message):
            unavailable("Not logged in to GitHub", icon: "person.crop.circle.badge.exclamationmark",
                        text: message, command: "gh auth login")
        case .failed(let message):
            unavailable("Could not list pull requests", icon: "exclamationmark.triangle", text: message, command: nil)
        case .idle:
            ProgressView("Loading pull requests…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where prs.pullRequests.isEmpty:
            ContentUnavailableView {
                Label("No open pull requests", systemImage: "arrow.triangle.pull")
            } description: {
                Text("\(repo.displayName) has no open pull request.")
            }
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(prs.pullRequests) { pr in
                        PullRequestRow(pr: pr, repo: repo, scope: scope)
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func unavailable(_ title: String, icon: String, text: String, command: String?) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            VStack(spacing: 8) {
                Text(text)
                    .lineLimit(6)
                    .textSelection(.enabled)
                if let command {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                        .textSelection(.enabled)
                }
            }
        } actions: {
            Button("Retry") { Task { await model.pullRequests.refresh() } }
                .disabled(model.pullRequests.gh == nil)
        }
    }

    @ViewBuilder
    private var countBadge: some View {
        if case .loaded = model.pullRequests.status {
            let count = model.pullRequests.pullRequests.count
            Text(count == 1 ? "1 open" : "\(count) open")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var refreshHelp: String {
        if let last = model.pullRequests.lastRefresh {
            return "Refresh (last: \(last.formatted(date: .omitted, time: .shortened)); automatic every 3 min)"
        }
        return "Refresh"
    }

    /// `https://github.com/<owner>/<repo>/pulls` from the origin remote, else the first PR's list page.
    private func pullsURL(_ repo: RepoState) -> URL? {
        if let remote = repo.facts?.remote, let host = remote.host, let owner = remote.owner {
            return URL(string: "https://\(host)/\(owner)/\(remote.name)/pulls")
        }
        if let first = model.pullRequests.pullRequests.first {
            return first.url.deletingLastPathComponent()
        }
        return nil
    }
}
