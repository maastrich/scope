import SwiftUI
import ScopeGit

/// History section: the last commits of the base (short sha, subject, author, relative date).
struct BaseHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let base = model.base
        if base.commits.isEmpty {
            Group {
                if base.isLoadingHistory {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No commits").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(base.commits) { commit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(commit.short)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                        Text(commit.subject)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 4) {
                        Text(commit.author)
                        Text("·")
                        Text(commit.date.formatted(.relative(presentation: .named)))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy SHA") { Pasteboard.copy(commit.sha) }
                }
            }
            .listStyle(.inset)
        }
    }
}
