import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

/// The plain-words reading of a checkout that died because git could not start `git-lfs`.
struct GitFailureHintTests {
    private let stderr = """
        Preparing worktree (new branch 'feat/lcm-geoplanner-map')
        git-lfs filter-process: git-lfs: command not found
        fatal: the remote end hung up unexpectedly
        """

    @Test func recognisesTheFilterAndTheHookMessages() {
        #expect(GitFailureHint.isLFSMissing(stderr))
        #expect(GitFailureHint.isLFSMissing(
            "This repository is configured for Git LFS but 'git-lfs' was not found on your path."))
        #expect(!GitFailureHint.isLFSMissing("fatal: invalid reference: origin/master"))
        #expect(GitFailureHint.explain("fatal: not a git repository", path: "/usr/bin", home: "/Users/u", isExecutable: { _ in true }) == nil)
    }

    @Test func installedButNotOnPATHSaysSoAndNamesTheFolder() throws {
        let hint = try #require(GitFailureHint.explain(stderr, path: "/usr/bin:/bin", home: "/Users/u",
                                                       isExecutable: { $0 == "/opt/homebrew/bin/git-lfs" }))
        #expect(hint.hasPrefix("git-lfs is installed (/opt/homebrew/bin/git-lfs) but not on Scope's PATH"))
        #expect(hint.contains("Add /opt/homebrew/bin to the PATH"))
    }

    @Test func nowhereSaysItIsNotInstalled() throws {
        let hint = try #require(GitFailureHint.explain(stderr, path: "/usr/bin:/bin", home: "/Users/u", isExecutable: { _ in false }))
        #expect(hint.hasPrefix("git-lfs is not installed"))
    }

    @Test func onPATHButStillFailingDoesNotBlameThePATH() throws {
        let hint = try #require(GitFailureHint.explain(stderr, path: "/opt/homebrew/bin:/usr/bin", home: "/Users/u",
                                                       isExecutable: { $0 == "/opt/homebrew/bin/git-lfs" }))
        #expect(hint.hasPrefix("git-lfs is on Scope's PATH"))
    }

    @Test func theHintLeadsTheErrorDescription() {
        let result = ProcessResult(exitCode: 128, terminationReason: .exit, stdout: Data(), stderr: Data(stderr.utf8))
        let error = GitError(arguments: ["worktree", "add", "/sb/geo", "-b", "feat/x", "origin/master"], result: result)
        #expect(error.hint != nil)
        #expect(error.description.hasPrefix(error.hint ?? "?"))
        #expect(error.description.contains("git worktree add /sb/geo -b feat/x origin/master failed (128)"))
    }
}
