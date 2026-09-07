import SwiftUI
import ScopeGit

/// *Base vs origin* mode: per repo, ahead / behind counts and the two commit lists.
struct DeltaBaseVsOriginView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.delta.repos) { repo in
                    HStack(spacing: 6) {
                        Text(repo.repo.isScopeRoot ? task.record.scopeName : repo.repo.name)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let delta = repo.delta {
                            Text("↑\(delta.ahead) ahead · ↓\(delta.behind) behind")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.03))
                    if let error = repo.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    } else if let delta = repo.delta {
                        if delta.commitsAhead.isEmpty, delta.commitsBehind.isEmpty {
                            Text("In sync with \(delta.base ?? "origin")")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 30)
                                .frame(height: 24)
                        }
                        commitList("Ahead", delta.commitsAhead, tint: DeltaCounts.added)
                        commitList("Behind", delta.commitsBehind, tint: DeltaCounts.removed)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func commitList(_ title: String, _ commits: [DeltaCommit], tint: Color) -> some View {
        if !commits.isEmpty {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 30)
                .frame(height: 22)
            ForEach(commits) { commit in
                HStack(spacing: 8) {
                    Text(commit.shortSHA)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(commit.subject)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 30)
                .frame(height: 22)
                .help(commit.sha)
            }
        }
    }
}
