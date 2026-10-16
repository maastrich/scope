import SwiftUI
import ScopeCore
import ScopeTasks

/// "Your checkout is on <task> since 12:04 — Put back": the band that says a base checkout is running a task's
/// branch (spec §4.5), on the task and on the Base panel of the repository. Prominent on purpose: the base is
/// never touched otherwise, so while it is, nothing should let the user forget it. Refresh moves the detached
/// checkout to the branch's current head; Put back restores the branch and the stash.
struct TryBanner: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    /// The sessions the banner speaks for: every one of the task's on the task, the shown repository's on Base.
    let sessions: [TrySession]
    /// Where the banner sits, for the usage log.
    let placement: String
    @State private var busy = false

    var body: some View {
        if let first = sessions.first {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color("WarningText"))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(first))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(first))
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if busy {
                    ScopeSpinner(size: 10)
                } else {
                    Button {
                        run("refresh") { try await model.refreshTry(task) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.headerChip)
                    .help("Move your checkout to the current head of \(task.branch)")
                    .usageID("\(placement).try-refresh", label: "Refresh my checkout")
                    Button {
                        run("put back") { try await model.putBack(task) }
                    } label: {
                        Label("Put back", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.headerChip)
                    .help("Back on \(sessions.map(\.previousLabel).joined(separator: ", ")), with your uncommitted changes")
                    .usageID("\(placement).try-put-back", label: "Put my checkout back")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color("WarningText").opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color("WarningText").opacity(0.35)))
            .accessibilityElement(children: .combine)
        }
    }

    private func title(_ first: TrySession) -> String {
        let since = first.since.formatted(date: .omitted, time: .shortened)
        if first.isEnding { return "Putting your checkout back from \(task.name)…" }
        if sessions.count > 1 {
            let names = sessions.compactMap { task.record.repo(at: $0.repoRelativePath)?.name }.joined(separator: ", ")
            return "Your checkouts of \(names) are on \(task.name) since \(since)"
        }
        return "Your checkout is on \(task.name) since \(since)"
    }

    private func subtitle(_ first: TrySession) -> String {
        let back = sessions.map(\.previousLabel).joined(separator: ", ")
        var line = "Detached at \(task.branch) @ \(String(first.head.prefix(7))). Put back returns to \(back)"
        line += sessions.contains { $0.stashSHA != nil } ? " and restores your stashed changes." : "."
        return line + " The task's threads keep working in the sandbox."
    }

    private func run(_ what: String, _ action: @escaping () async throws -> String) {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await action() } catch {
                model.problems.error("Could not \(what) your checkout for \(task.name)", detail: String(describing: error), scope: task.scopeID)
            }
        }
    }
}
