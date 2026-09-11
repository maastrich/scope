import Foundation
import ScopeCore
import ScopeTasks

/// The review comments of the task the Delta panel follows, saved as they change (`ReviewStore`, under
/// `SCOPE_HOME`).
@MainActor
@Observable
final class ReviewModel {
    private(set) var taskID: TaskID?
    private(set) var comments: [ReviewComment] = []
    @ObservationIgnored let store: ReviewStore
    @ObservationIgnored private let problems: ProblemCenter
    /// Saves run one after the other, so an older list never lands after a newer one.
    @ObservationIgnored private var saving: Task<Void, Never>?

    init(home: URL, problems: ProblemCenter) {
        self.store = ReviewStore(home: home)
        self.problems = problems
    }

    func show(task: TaskID) async {
        guard taskID != task else { return }
        taskID = task
        comments = []
        let loaded = await store.load(task)
        guard taskID == task else { return }
        comments = loaded
    }

    func comments(repo: String, path: String) -> [ReviewComment] {
        comments.filter { $0.repo == repo && $0.path == path }
    }

    func add(_ comment: ReviewComment) {
        comments.append(comment)
        persist()
    }

    func update(_ id: UUID, body: String) {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        comments[index].body = body
        persist()
    }

    func delete(_ id: UUID) {
        comments.removeAll { $0.id == id }
        persist()
    }

    /// Drops comments once they reached the thread, whether or not the panel still shows their task.
    func remove(_ ids: Set<UUID>, from task: TaskID) async {
        if taskID == task {
            comments.removeAll { ids.contains($0.id) }
            persist()
            return
        }
        var stored = await store.load(task)
        stored.removeAll { ids.contains($0.id) }
        try? await store.save(stored, for: task)
    }

    private func persist() {
        guard let taskID else { return }
        let snapshot = comments
        let store = store
        let previous = saving
        saving = Task { [problems] in
            await previous?.value
            do {
                try await store.save(snapshot, for: taskID)
            } catch {
                problems.warn("Could not save the review comments", detail: String(describing: error))
            }
        }
    }
}

/// Text waiting for a thread to finish its turn.
struct PendingDelivery: Identifiable {
    let id = UUID()
    let text: String
    /// `a review of 3 comments`, for the panels that say what is queued.
    let label: String
    let onDelivered: @MainActor () -> Void
}

extension AppModel {
    enum DeliveryOutcome: Equatable {
        case sent
        /// The thread is mid-turn: sent when its hooks say the turn ended.
        case queued
        case failed(String)
    }

    /// Hands `text` to a thread as one input — what `thread.send` types, wrapped in a bracketed paste — now when
    /// the thread is between turns, otherwise once its turn ends. Messages to one thread go out one per turn, in
    /// order.
    @discardableResult
    func deliver(_ text: String, to id: ThreadID, label: String,
                 onDelivered: @escaping @MainActor () -> Void = {}) -> DeliveryOutcome {
        guard let session = session(id), session.isAlive else { return .failed("the thread is not running") }
        let item = PendingDelivery(text: text, label: label, onDelivered: onDelivered)
        guard ThreadDelivery.canDeliver(to: session.displayState), (pendingDeliveries[id] ?? []).isEmpty else {
            pendingDeliveries[id, default: []].append(item)
            return .queued
        }
        paste(item, into: session)
        return .sent
    }

    /// Called on every hook event: the first queued message goes out when the thread is between turns again.
    func flushDeliveries(for session: ThreadSession) {
        guard ThreadDelivery.canDeliver(to: session.displayState), var queue = pendingDeliveries[session.id],
              !queue.isEmpty else { return }
        let next = queue.removeFirst()
        pendingDeliveries[session.id] = queue.isEmpty ? nil : queue
        paste(next, into: session)
    }

    /// A thread that exits takes its queue with it; the text is kept in the Problem Center so nothing is lost.
    func dropDeliveries(for session: ThreadSession) {
        guard let queue = pendingDeliveries.removeValue(forKey: session.id), !queue.isEmpty else { return }
        problems.warn("\(queue.map(\.label).joined(separator: ", ")) never reached \(session.title)",
                      detail: queue.map(\.text).joined(separator: "\n\n———\n\n"), scope: session.record.scopeID)
    }

    /// The live threads of `task` that already hold a queued message.
    func queuedDelivery(in task: TaskState) -> (session: ThreadSession, delivery: PendingDelivery)? {
        for session in threads(in: task.id) {
            if let first = pendingDeliveries[session.id]?.first { return (session, first) }
        }
        return nil
    }

    private func paste(_ item: PendingDelivery, into session: ThreadSession) {
        session.send(ThreadDelivery.bracketedPaste(item.text))
        // Return goes on its own, a beat later: a TUI still busy digesting a long paste can take a Return that
        // arrives with it as part of the paste rather than as "submit".
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard session.isAlive else { return }
            session.send("\r")
        }
        item.onDelivered()
    }

    /// Renders the task's comments against the files as they are now and delivers them to `thread`. The comments
    /// are cleared once the text reached the thread.
    func sendReview(for task: TaskState, to thread: ThreadID) async -> DeliveryOutcome {
        await review.show(task: task.id)
        let comments = review.comments
        guard !comments.isEmpty else { return .failed("there is no comment to send") }
        let record = task.record
        let text = ReviewRenderer.render(comments, repoName: { $0 == "." ? record.scopeName : $0 }) { comment in
            guard let repo = record.repo(at: comment.repo),
                  let content = try? String(contentsOf: repo.sandboxURL.appending(path: comment.path), encoding: .utf8)
            else { return nil }
            var lines = content.components(separatedBy: "\n")
            if content.hasSuffix("\n") { lines.removeLast() }
            return lines
        }
        let ids = Set(comments.map(\.id))
        let taskID = task.id
        let label = comments.count == 1 ? "a review comment" : "a review of \(comments.count) comments"
        return deliver(text, to: thread, label: label) { [weak self] in
            Task { await self?.review.remove(ids, from: taskID) }
        }
    }
}
