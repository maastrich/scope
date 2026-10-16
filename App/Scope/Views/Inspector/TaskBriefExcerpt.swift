import SwiftUI
import ScopeCore

/// The brief at the top of the Task section: its first lines, and *Read in full* for the rest in the reading column.
/// Before this the brief waited 700 ms in the hover card, and a brief is a page (median 2.6k characters).
/// A task restored from the archive also offers what was kept at archive, when anything was.
struct TaskBriefExcerpt: View {
    @Environment(AppModel.self) private var model
    let task: TaskState

    var body: some View {
        let prompt = task.record.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kept = model.deliverable(of: task)
        if !prompt.isEmpty || kept != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !prompt.isEmpty {
                    Text(Self.excerpt(prompt))
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if !prompt.isEmpty {
                        Button("Read in full") { model.readBrief(of: task) }
                            .help("The whole brief, in the reading column")
                            .usageID("inspector.task.read-brief", label: "Read the brief in full")
                    }
                    if let kept {
                        Button("Read deliverable") { model.readDeliverable(of: task) }
                            .help(Self.keptHelp(kept))
                            .usageID("inspector.task.read-deliverable", label: "Read the deliverable")
                    }
                }
                .buttonStyle(.plain)
                .font(.scopeCaption)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    /// Headings and rules make a four-line excerpt say nothing; the text under them does.
    static func excerpt(_ prompt: String) -> String {
        prompt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.allSatisfy { "-=*_`".contains($0) } }
            .prefix(6)
            .joined(separator: " ")
    }

    static func keptHelp(_ kept: TaskDeliverable) -> String {
        var parts: [String] = []
        if !kept.files.isEmpty { parts.append(kept.files.map(\.name).joined(separator: ", ")) }
        if !kept.replies.isEmpty { parts.append("the last answer of \(kept.replies.count) thread\(kept.replies.count == 1 ? "" : "s")") }
        return "Kept when the task was archived: " + parts.joined(separator: " and ")
    }
}
