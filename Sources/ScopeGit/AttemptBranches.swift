import Foundation
import ScopeCore

/// A branch that cannot be renamed because its new name is taken: someone's work, not a name to take over.
public struct BranchExistsError: Error, Sendable, Equatable, CustomStringConvertible {
    public let branch: String
    public var description: String { "branch \(branch) already exists" }
}

public extension GitClient {
    /// `git branch -m <from> <to>` run in `checkout`: the worktree whose HEAD is `from` follows the rename. The
    /// upstream, if any, pointed at the old name on the remote, so it is dropped: the next push says where it goes
    /// (`git push -u`). Refused when `to` exists.
    func moveBranch(from: String, to: String, in checkout: URL) async throws {
        guard from != to else { return }
        let c = ["-C", checkout.filesystemPath]
        if await branchExists(to) { throw GitError(arguments: ["branch", "-m", from, to], result: ProcessResult(
            exitCode: 128, terminationReason: .exit, stdout: Data(), stderr: Data("branch \(to) already exists".utf8))) }
        try await run(c + ["branch", "-m", from, to], timeout: .seconds(30))
        _ = try? await run(c + ["branch", "--unset-upstream", to], timeout: .seconds(10), allowFailure: true)
    }
}

public extension Delta {
    /// The files that differ between two attempts' branches — `git diff <from> <to>`, commits only — read from
    /// `checkout`, which can be either worktree of the repository: both branches live in it. Uncommitted work shows
    /// in the attempt-vs-base view (`Delta.load(mode: .task)`), not here: a two-sided working-tree diff has no
    /// honest answer.
    static func compare(from: String, to: String, in checkout: URL, using client: GitClient) async throws -> [DiffFile] {
        let c = ["-C", checkout.filesystemPath]
        let files = try await patch(c + diffArguments + [from, to], numstat: c + diffArguments + ["--numstat", "-z", from, to],
                                    using: client)
        return sorted(files)
    }
}
