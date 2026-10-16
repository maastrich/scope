import Foundation
import ScopeCore
import ScopeGit

/// One snapshot of every sandbox of a task (spec §4.3, *Checkpoints*): taken when a turn ends, so the owner can read
/// what a turn changed and go back to it. Each sandbox's working tree — tracked and untracked, ignored excluded,
/// files over `WorkingTreeSnapshot.fileLimit` excluded and named — is committed through a private index on top of
/// the sandbox's `HEAD`, and the commit kept under `refs/scope/checkpoints/<task-id>/<n>` in the repository. The
/// branch never moves; the sandbox's own index is never touched.
public struct TaskCheckpoint: Codable, Sendable, Equatable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        /// A turn ended (or failed) in one of the task's threads.
        case turn
        /// Taken just before a restore, so the state being replaced is itself a checkpoint: the undo.
        case beforeRestore
    }

    /// One sandbox's part of the checkpoint.
    public struct Repo: Codable, Sendable, Equatable {
        public var repoRelativePath: String
        /// The snapshot commit, under the checkpoint's ref in this repository.
        public var commit: String
        /// Its tree: what says whether anything changed since.
        public var tree: String
        /// Lines against the previous checkpoint of the same sandbox (its `HEAD` for the first).
        public var additions: Int
        public var deletions: Int
        /// Untracked files left out for their size.
        public var skipped: [String]

        public init(repoRelativePath: String, commit: String, tree: String, additions: Int = 0, deletions: Int = 0, skipped: [String] = []) {
            self.repoRelativePath = repoRelativePath
            self.commit = commit
            self.tree = tree
            self.additions = additions
            self.deletions = deletions
            self.skipped = skipped
        }
    }

    /// Counts up within the task and is never reused, so a ref name always means the same snapshot.
    public var number: Int
    public var at: Date
    public var reason: Reason
    /// The thread whose turn ended; `nil` for a pre-restore checkpoint.
    public var threadID: String?
    public var threadTitle: String?
    /// The turn's rank in its thread (1 for the first), and when it ended: what the timeline matches a bar on.
    public var turn: Int?
    public var turnEndedAt: Date?
    /// The first words of the reply, when the driver said.
    public var said: String?
    /// For a pre-restore checkpoint: the checkpoint that was restored.
    public var restoring: Int?
    public var repos: [Repo]

    public init(number: Int, at: Date, reason: Reason = .turn, threadID: String? = nil, threadTitle: String? = nil,
                turn: Int? = nil, turnEndedAt: Date? = nil, said: String? = nil, restoring: Int? = nil, repos: [Repo]) {
        self.number = number
        self.at = at
        self.reason = reason
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.turn = turn
        self.turnEndedAt = turnEndedAt
        self.said = said
        self.restoring = restoring
        self.repos = repos
    }

    public var id: Int { number }
    public var additions: Int { repos.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { repos.reduce(0) { $0 + $1.deletions } }

    /// What the list shows under the time: the reply's first words, or what the checkpoint is.
    public var headline: String {
        if let said, !said.isEmpty { return said }
        switch reason {
        case .beforeRestore: return "Before restoring checkpoint \(restoring.map(String.init) ?? "")".trimmingCharacters(in: .whitespaces)
        case .turn: return turn.map { "Turn \($0)" } ?? "Checkpoint"
        }
    }
}

/// `<home>/tasks/<id>.checkpoints.json`: the task's checkpoints, newest last, and the next number to hand out.
public struct TaskCheckpointLog: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var next: Int
    public var checkpoints: [TaskCheckpoint]

    public init(next: Int = 1, checkpoints: [TaskCheckpoint] = []) {
        version = Self.currentVersion
        self.next = next
        self.checkpoints = checkpoints
    }

    public func checkpoint(_ number: Int) -> TaskCheckpoint? {
        checkpoints.first { $0.number == number }
    }
}

/// Owner of the checkpoint logs, beside the task records. `TaskRecordStore.loadAll` skips them (their stem is not a
/// task id).
public actor TaskCheckpointStore {
    public nonisolated let directory: URL

    public init(home: URL) {
        directory = TaskRecordStore.directoryURL(home: home)
    }

    public nonisolated func url(for id: TaskID) -> URL {
        directory.appending(path: "\(id.rawValue).checkpoints.json", directoryHint: .notDirectory)
    }

    /// An empty log when there is none, or it is unreadable or from another version.
    public func load(_ id: TaskID) -> TaskCheckpointLog {
        guard let log = try? JSONStore.load(TaskCheckpointLog.self, from: url(for: id), fractionalSeconds: true),
              log.version == TaskCheckpointLog.currentVersion else { return TaskCheckpointLog() }
        return log
    }

    public func save(_ log: TaskCheckpointLog, for id: TaskID) throws {
        try JSONStore.save(log, to: url(for: id), fractionalSeconds: true)
    }

    /// Missing file is not an error.
    public func delete(_ id: TaskID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

/// Takes, lists, restores, branches and prunes the checkpoints of tasks. One actor for every task, so two turns
/// ending at once in two threads of a task never write the same number twice.
public actor TaskCheckpoints {
    public static let namespace = "refs/scope/checkpoints"
    /// Checkpoints kept on an open task; the oldest go as new ones come.
    public static let keepOpen = 50
    /// Checkpoints kept with the record of an archived task.
    public static let keepArchived = 5
    /// How long the app waits after a turn's end before taking the checkpoint, so turns seconds apart share one.
    public static let debounce: Duration = .seconds(3)

    private let registry: GitClientRegistry
    private let store: TaskCheckpointStore

    public init(home: URL, registry: GitClientRegistry) {
        self.registry = registry
        self.store = TaskCheckpointStore(home: home)
    }

    /// `refs/scope/checkpoints/<task-id>/<n>`
    public static func ref(task: TaskID, number: Int) -> String {
        "\(namespace)/\(task.rawValue)/\(number)"
    }

    /// The task id a checkpoint ref names, `nil` for anything else.
    public static func taskID(ofRef ref: String) -> String? {
        guard ref.hasPrefix(namespace + "/") else { return nil }
        let rest = ref.dropFirst(namespace.count + 1).split(separator: "/")
        guard rest.count == 2, Int(rest[1]) != nil else { return nil }
        return String(rest[0])
    }

    /// The turn a checkpoint records.
    public struct TurnInfo: Sendable, Equatable {
        public var threadID: String
        public var threadTitle: String
        /// The turn's rank in its thread (1 for the first).
        public var turn: Int
        public var endedAt: Date
        public var said: String?

        public init(threadID: String, threadTitle: String, turn: Int, endedAt: Date, said: String? = nil) {
            self.threadID = threadID
            self.threadTitle = threadTitle
            self.turn = turn
            self.endedAt = endedAt
            self.said = said
        }
    }

    /// The task's checkpoints, oldest first.
    public func list(_ task: TaskID) async -> [TaskCheckpoint] {
        await store.load(task).checkpoints
    }

    /// Snapshots every active sandbox of `task`. `nil` when no sandbox changed since the last checkpoint, or when
    /// there is no sandbox to snapshot (a base checkout is never one). A sandbox left as it was shares the previous
    /// checkpoint's commit under the new number, so a checkpoint always names every sandbox.
    @discardableResult
    public func snapshot(_ task: TaskRecord, turn: TurnInfo?, reason: TaskCheckpoint.Reason = .turn,
                         restoring: Int? = nil, at date: Date = .now) async throws -> TaskCheckpoint? {
        var log = await store.load(task.id)
        let previous = log.checkpoints.last
        let number = log.next
        var repos: [TaskCheckpoint.Repo] = []
        var changed = false
        for repo in Self.sandboxes(of: task) {
            let client = await registry.client(for: repo.sandboxURL)
            do {
                let tree = try await WorkingTreeSnapshot.writeTree(of: repo.sandboxURL, using: client)
                let last = previous?.repos.first { $0.repoRelativePath == repo.repoRelativePath }
                if let last, last.tree == tree.hash {
                    repos.append(TaskCheckpoint.Repo(repoRelativePath: repo.repoRelativePath, commit: last.commit, tree: tree.hash,
                                                     skipped: tree.skipped))
                    continue
                }
                changed = true
                var baseline = last?.tree
                if baseline == nil { baseline = try await client.output(["-C", repo.sandboxURL.filesystemPath, "rev-parse", "HEAD^{tree}"]) }
                guard let baseline else { continue }
                let counts = try await WorkingTreeSnapshot.counts(from: baseline, to: tree.hash, in: repo.sandboxURL, using: client)
                let message = Self.message(task: task, number: number, turn: turn, reason: reason, restoring: restoring)
                let commit = try await WorkingTreeSnapshot.commit(tree: tree.hash, message: message, ref: Self.ref(task: task.id, number: number),
                                                                  in: repo.sandboxURL, using: client)
                repos.append(TaskCheckpoint.Repo(repoRelativePath: repo.repoRelativePath, commit: commit, tree: tree.hash,
                                                 additions: counts.additions, deletions: counts.deletions, skipped: tree.skipped))
            } catch let error as GitError {
                throw TaskError.git(repo: repo.repoRelativePath, error)
            }
        }
        guard changed, !repos.isEmpty else { return nil }
        // The sandboxes that did not move point at the previous commit: the new ref must still exist in each.
        for entry in repos {
            guard let repo = task.repo(at: entry.repoRelativePath) else { continue }
            let client = await registry.client(for: repo.sandboxURL)
            try? await client.run(["-C", repo.sandboxURL.filesystemPath, "update-ref", Self.ref(task: task.id, number: number), entry.commit])
        }
        let checkpoint = TaskCheckpoint(
            number: number, at: TaskRecord.roundedToMilliseconds(date), reason: reason,
            threadID: turn?.threadID, threadTitle: turn?.threadTitle, turn: turn?.turn,
            turnEndedAt: turn.map { TaskRecord.roundedToMilliseconds($0.endedAt) }, said: turn?.said, restoring: restoring, repos: repos
        )
        log.next = number + 1
        log.checkpoints.append(checkpoint)
        let dropped = log.checkpoints.count > Self.keepOpen ? Array(log.checkpoints.prefix(log.checkpoints.count - Self.keepOpen)) : []
        log.checkpoints.removeFirst(dropped.count)
        try await save(log, for: task)
        await deleteRefs(of: dropped, task: task)
        return checkpoint
    }

    /// What a restore did: the checkpoint put back, and the one taken first (the undo) — the last checkpoint when
    /// the working tree had not moved since it.
    public struct Restoration: Sendable, Equatable {
        public var restored: TaskCheckpoint
        public var undo: TaskCheckpoint?
    }

    /// Checks the checkpoint's tree out into every sandbox's working tree: files it had are written back, files that
    /// appeared since are removed. The branch, its commits and the sandbox's index stay as they are. The working
    /// tree as it was is checkpointed first, so nothing is lost.
    public func restore(_ task: TaskRecord, number: Int) async throws -> Restoration {
        let log = await store.load(task.id)
        guard let target = log.checkpoint(number) else { throw TaskError.checkpointNotFound(number) }
        let undo = try await snapshot(task, turn: nil, reason: .beforeRestore, restoring: number) ?? log.checkpoints.last
        for entry in target.repos {
            guard let repo = Self.sandboxes(of: task).first(where: { $0.repoRelativePath == entry.repoRelativePath }) else { continue }
            let sandbox = repo.sandboxURL
            let client = await registry.client(for: sandbox)
            do {
                var now = undo?.repos.first { $0.repoRelativePath == entry.repoRelativePath }?.tree
                if now == nil { now = try await WorkingTreeSnapshot.writeTree(of: sandbox, using: client).hash }
                guard let now else { continue }
                // Files the checkpoint did not have, untracked ones included: `restore` only knows the index.
                let appeared = try await client.run(["-C", sandbox.filesystemPath, "diff", "--name-only", "-z", "--diff-filter=A",
                                                     entry.tree, now])
                    .stdoutText.split(separator: "\0").map(String.init)
                for path in appeared {
                    let file = sandbox.appending(path: path, directoryHint: .notDirectory).standardizedFileURL
                    guard file.path.hasPrefix(sandbox.standardizedFileURL.path + "/") else { continue }
                    try? FileManager.default.removeItem(at: file)
                }
                try await client.run(["-C", sandbox.filesystemPath, "restore", "--source=\(entry.commit)", "--worktree", "--no-overlay", "--", "."],
                                     timeout: .seconds(600))
            } catch let error as GitError {
                throw TaskError.git(repo: repo.repoRelativePath, error)
            }
        }
        return Restoration(restored: target, undo: undo)
    }

    /// `<branch>-cp<n>` at the checkpoint's commit, in every repository of the task. Nothing is checked out.
    @discardableResult
    public func branch(_ task: TaskRecord, from number: Int) async throws -> String {
        let log = await store.load(task.id)
        guard let target = log.checkpoint(number) else { throw TaskError.checkpointNotFound(number) }
        let name = "\(task.branch)-cp\(number)"
        for entry in target.repos {
            let client = await client(for: entry.repoRelativePath, task: task)
            do {
                try await client.run(["branch", name, entry.commit])
            } catch let error as GitError {
                throw TaskError.git(repo: entry.repoRelativePath, error)
            }
        }
        return name
    }

    /// One sandbox's files that differ between the checkpoint and its working tree now.
    public struct RepoDiff: Sendable, Equatable {
        public var repoRelativePath: String
        public var files: [DiffFile]
    }

    /// The checkpoint against the sandboxes as they are now, with the hunks: what *Show diff* reads.
    public func diff(_ task: TaskRecord, number: Int) async throws -> [RepoDiff] {
        let log = await store.load(task.id)
        guard let target = log.checkpoint(number) else { throw TaskError.checkpointNotFound(number) }
        var result: [RepoDiff] = []
        for entry in target.repos {
            guard let repo = Self.sandboxes(of: task).first(where: { $0.repoRelativePath == entry.repoRelativePath }) else { continue }
            let client = await registry.client(for: repo.sandboxURL)
            do {
                let now = try await WorkingTreeSnapshot.writeTree(of: repo.sandboxURL, using: client)
                let files = try await WorkingTreeSnapshot.diff(from: entry.tree, to: now.hash, in: repo.sandboxURL, using: client)
                result.append(RepoDiff(repoRelativePath: entry.repoRelativePath, files: files))
            } catch let error as GitError {
                throw TaskError.git(repo: entry.repoRelativePath, error)
            }
        }
        return result
    }

    /// Keeps the last `keep` checkpoints of the task and deletes the refs of the rest. The refs deleted.
    @discardableResult
    public func prune(_ task: TaskRecord, keep: Int) async -> [String] {
        var log = await store.load(task.id)
        guard log.checkpoints.count > keep else { return [] }
        let dropped = Array(log.checkpoints.prefix(log.checkpoints.count - keep))
        log.checkpoints.removeFirst(dropped.count)
        try? await save(log, for: task)
        return await deleteRefs(of: dropped, task: task)
    }

    /// Every checkpoint of a task that is closed: refs and log.
    public func forget(_ task: TaskRecord) async {
        let log = await store.load(task.id)
        await deleteRefs(of: log.checkpoints, task: task)
        await store.delete(task.id)
    }

    /// The checkpoint refs in a repository whose task is in none of `knownTasks` (ids) and whose snapshot is older
    /// than `retention`: a close that never finished, a record lost. What `scope gc` deletes. The age guard is what
    /// keeps a Debug build, whose home knows none of the installed app's tasks, from deleting its live checkpoints
    /// in a repository the two share — the same 30 days as a salvage ref.
    public static func orphanRefs(in client: GitClient, knownTasks: Set<String>, olderThan retention: TimeInterval,
                                  now: Date = .now) async -> [String] {
        let listing = (try? await client.output(["for-each-ref", "--format=%(refname) %(committerdate:unix)", namespace])) ?? ""
        return listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let id = taskID(ofRef: String(fields[0])), !knownTasks.contains(id),
                  let stamp = TimeInterval(fields[1]), now.timeIntervalSince(Date(timeIntervalSince1970: stamp)) > retention
            else { return nil }
            return String(fields[0])
        }
    }

    // MARK: - Internals

    /// The sandboxes a checkpoint covers: active, on disk, and never the base checkout itself.
    static func sandboxes(of task: TaskRecord) -> [TaskRepo] {
        task.activeRepos.filter { repo in
            let base = TaskManager.baseURL(scopeRoot: task.scopeRoot, repoRelativePath: repo.repoRelativePath)
            return repo.sandboxURL.standardizedFileURL.path != base.standardizedFileURL.path
                && FileManager.default.fileExists(atPath: repo.sandboxURL.appending(path: ".git").path)
        }
    }

    static func message(task: TaskRecord, number: Int, turn: TurnInfo?, reason: TaskCheckpoint.Reason, restoring: Int?) -> String {
        var line = "Scope checkpoint \(number) of \(task.name)"
        switch reason {
        case .beforeRestore:
            line += ": before restoring checkpoint \(restoring.map(String.init) ?? "")"
        case .turn:
            if let turn {
                line += ": turn \(turn.turn) of \(turn.threadTitle)"
                if let said = turn.said, !said.isEmpty { line += " — \(said)" }
            }
        }
        return line
    }

    /// The sandbox's client while it is there, the base's once it is gone: the refs live in the repository either way.
    private func client(for repoRelativePath: String, task: TaskRecord) async -> GitClient {
        if let repo = task.repo(at: repoRelativePath), FileManager.default.fileExists(atPath: repo.sandboxURL.appending(path: ".git").path) {
            return await registry.client(for: repo.sandboxURL)
        }
        return await registry.client(for: TaskManager.baseURL(scopeRoot: task.scopeRoot, repoRelativePath: repoRelativePath))
    }

    @discardableResult
    private func deleteRefs(of checkpoints: [TaskCheckpoint], task: TaskRecord) async -> [String] {
        var deleted: [String] = []
        for checkpoint in checkpoints {
            let ref = Self.ref(task: task.id, number: checkpoint.number)
            for entry in checkpoint.repos {
                let client = await client(for: entry.repoRelativePath, task: task)
                if (try? await client.run(["update-ref", "-d", ref])) != nil { deleted.append("\(entry.repoRelativePath): \(ref)") }
            }
        }
        return deleted
    }

    private func save(_ log: TaskCheckpointLog, for task: TaskRecord) async throws {
        do { try await store.save(log, for: task.id) } catch { throw TaskError.persistence(String(describing: error)) }
    }
}
