import SwiftUI
import ScopeCore
import ScopeTasks

/// The strip above the Delta action bar while the task has review comments: how many, the list to edit them, what
/// is queued, and **Send Review** — to the task's only running thread, or to the one picked from a menu.
struct ReviewBar: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    @State private var showsList = false

    var body: some View {
        let count = model.review.comments.count
        let live = model.threads(in: task.id).filter(\.isAlive)
        HStack(spacing: 8) {
            Button {
                showsList.toggle()
            } label: {
                Label(count == 1 ? "1 comment" : "\(count) comments", systemImage: "text.bubble")
            }
            .buttonStyle(.borderless)
            .help("List, edit and delete the comments")
            .popover(isPresented: $showsList, arrowEdge: .top) {
                ReviewCommentList(task: task)
            }

            if let queued = model.queuedDelivery(in: task) {
                Label("\(queued.delivery.label.capitalizedFirst) waits for \(model.displayTitle(for: queued.session)) to finish its turn",
                      systemImage: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if live.count > 1 {
                Menu("Send Review") {
                    ForEach(live) { session in
                        Button(model.displayTitle(for: session)) { send(to: session.id) }
                    }
                }
                .fixedSize()
                .help("Paste the review into one of the task's threads")
            } else {
                Button("Send Review") {
                    if let only = live.first { send(to: only.id) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(live.isEmpty || count == 0)
                .help(live.isEmpty ? "No thread of this task is running" : "Paste the review into \(model.displayTitle(for: live[0]))")
            }
        }
        .controlSize(.small)
        .padding(EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14))
        .background(Color("PanelBackground"))
    }

    private func send(to thread: ThreadID) {
        Task {
            if case .failed(let reason) = await model.sendReview(for: task, to: thread) {
                model.problems.warn("Could not send the review", detail: reason, scope: task.scopeID)
            }
        }
    }
}

/// The comments of the task, in file order: jump to the file, edit in place, delete.
private struct ReviewCommentList: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    @State private var editing: UUID?
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.review.comments.sorted { ($0.repo, $0.path, $0.anchor.line) < ($1.repo, $1.path, $1.anchor.line) }) { comment in
                    row(comment)
                }
            }
            .padding(12)
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
    }

    private func row(_ comment: ReviewComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(location(comment)) {
                    model.delta.selectedFile = DeltaFileRef(repo: comment.repo, path: comment.path)
                }
                .buttonStyle(.link)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    editing = comment.id
                    draft = comment.body
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit")
                Button {
                    model.review.delete(comment.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            if editing == comment.id {
                TextEditor(text: $draft)
                    .font(.system(size: 12))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button("Save") {
                        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !body.isEmpty { model.review.update(comment.id, body: body) }
                        editing = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                Text(comment.body)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func location(_ comment: ReviewComment) -> String {
        let repo = comment.repo == "." ? task.record.scopeName : comment.repo
        let lines = comment.anchor.span == 1 ? "\(comment.anchor.line)" : "\(comment.anchor.line)–\(comment.anchor.lastLine)"
        return "\(repo)/\(comment.path):\(lines)\(comment.side == .old ? " (removed)" : "")"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
