import Foundation
import ScopeCore

/// The review comments of every task, one `<home>/reviews/<task-id>.json` each. Under `SCOPE_HOME`, never in the
/// sandbox: a comment is a note to the agent, not a file of the branch.
public actor ReviewStore {
    public nonisolated let directory: URL

    public init(home: URL) {
        directory = home.appending(path: "reviews", directoryHint: .isDirectory)
    }

    public nonisolated func url(for task: TaskID) -> URL {
        directory.appending(path: "\(task.rawValue).json", directoryHint: .notDirectory)
    }

    /// The comments of `task`; none when there is no file or it cannot be read.
    public func load(_ task: TaskID) -> [ReviewComment] {
        (try? JSONStore.load([ReviewComment].self, from: url(for: task), fractionalSeconds: true)) ?? []
    }

    /// Writes the comments of `task`; an empty list removes its file.
    public func save(_ comments: [ReviewComment], for task: TaskID) throws {
        guard !comments.isEmpty else {
            delete(task)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONStore.save(comments, to: url(for: task), fractionalSeconds: true)
    }

    public func delete(_ task: TaskID) {
        try? FileManager.default.removeItem(at: url(for: task))
    }
}
