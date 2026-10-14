import SwiftUI
import ScopeGit

/// The History section: closed, the HEAD commit; open, the last commits of the base.
struct HistorySection: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var sash: SectionSash?

    var body: some View {
        CollapsibleSection(section: .history, bodyHeight: bodyHeight, unavailable: "no repository", sash: sash) {
            if let head = model.base.commits.first {
                HStack(spacing: 6) {
                    Text(head.short).font(.scopeValue)
                    Text(head.subject).truncationMode(.tail)
                    Text("· \(head.date.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize()
                }
            }
        } actions: {
            Button {
                Task { await model.base.loadHistory() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload the history")
            .accessibilityLabel("Reload the history")
        } content: {
            BaseHistoryView()
        }
    }
}

/// The body of the History section: the last commits of the base (short sha, subject, author, relative date).
struct BaseHistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let base = model.base
        if base.commits.isEmpty {
            Group {
                if base.isLoadingHistory {
                    ScopeSpinner(size: 14)
                } else {
                    Text("No commits").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(base.commits) { commit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(commit.short)
                            .font(.scopeValue)
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
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
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
