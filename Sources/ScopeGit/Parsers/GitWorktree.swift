import Foundation

/// One record of `git worktree list --porcelain`.
public struct GitWorktree: Sendable, Equatable {
    /// Absolute path of the checkout.
    public let path: String
    /// Commit checked out, `nil` for a bare worktree.
    public let head: String?
    /// Branch name with `refs/heads/` stripped; `nil` when detached or bare.
    public let branch: String?
    public let isDetached: Bool
    public let isBare: Bool
    public let isLocked: Bool
    /// Text after `locked`, when git reports one.
    public let lockReason: String?
    /// The checkout folder is gone; `git worktree prune` would drop the record.
    public let isPrunable: Bool

    public init(
        path: String,
        head: String? = nil,
        branch: String? = nil,
        isDetached: Bool = false,
        isBare: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        isPrunable: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
    }

    /// Parses `git worktree list --porcelain` output [verified].
    ///
    /// Records are separated by a blank line; each line is `<key>[ <value>]`:
    /// `worktree <path>`, `HEAD <sha>`, `branch refs/heads/<name>` or `detached`, optional
    /// `bare`, `locked [reason]`, `prunable [reason]`. Unknown keys are ignored.
    public static func parse(_ output: String) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var current = Builder()

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                current.flush(into: &result)
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : nil
            switch parts[0] {
            case "worktree": current.path = value
            case "HEAD": current.head = value
            case "branch": current.branch = value.map(Self.stripRefsHeads)
            case "detached": current.isDetached = true
            case "bare": current.isBare = true
            case "locked":
                current.isLocked = true
                current.lockReason = value
            case "prunable": current.isPrunable = true
            default: break
            }
        }
        current.flush(into: &result)
        return result
    }

    private static func stripRefsHeads(_ ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    /// Accumulates one record's lines; `flush` emits it when a `worktree` line was seen.
    private struct Builder {
        var path: String?
        var head: String?
        var branch: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false

        mutating func flush(into result: inout [GitWorktree]) {
            if let path {
                result.append(GitWorktree(
                    path: path, head: head, branch: branch, isDetached: isDetached, isBare: isBare,
                    isLocked: isLocked, lockReason: lockReason, isPrunable: isPrunable
                ))
            }
            self = Builder()
        }
    }
}
