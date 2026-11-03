import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

/// 33 of the 34 problems of 27/10–03/11 were journaled `unknown`: the cause was guessed from the detail's words. It
/// now comes from the error's type, and a notice that reports no failure says so.
@Suite struct ProblemCauseTests {
    private func gitError(_ stderr: String, exit: Int32 = 128) -> GitError {
        GitError(arguments: ["fetch", "origin"],
                 result: ProcessResult(exitCode: exit, terminationReason: .exit, stdout: Data(), stderr: Data(stderr.utf8)))
    }

    @Test func taskErrorsSayTheirCause() {
        #expect(ProblemCause.of(TaskError.branchNotFound(repo: "api", branch: "x")) == .missing)
        #expect(ProblemCause.of(TaskError.repoNotFound(repo: "api")) == .missing)
        #expect(ProblemCause.of(TaskError.taskArchived) == .archived)
        #expect(ProblemCause.of(TaskError.branchAlreadyCheckedOut(repo: "api", branch: "x", path: "/p")) == .busy)
        #expect(ProblemCause.of(TaskError.invalidBranch("scope/x")) == .invalid)
        #expect(ProblemCause.of(TaskError.persistence("no such task")) == .persistence)
        #expect(ProblemCause.of(TaskError.worktree(repo: "api", .uncommittedChanges(path: "/p"))) == .conflict)
    }

    @Test func aGitErrorIsReadFromItsStderrElseAnExit() {
        #expect(ProblemCause.of(TaskError.git(repo: "api", gitError("fatal: unable to access 'https://x/': Could not resolve host: github.com"))) == .network)
        #expect(ProblemCause.of(gitError("fatal: Unable to create '/r/.git/index.lock': File exists.")) == .conflict)
        #expect(ProblemCause.of(gitError("fatal: '/sandbox' already exists")) == .conflict)
        #expect(ProblemCause.of(gitError("", exit: 1)) == .exit)
    }

    @Test func subprocessErrorsSayTheirCause() {
        #expect(ProblemCause.of(SubprocessError.timedOut(after: .seconds(5))) == .timeout)
        #expect(ProblemCause.of(SubprocessError.launchFailed("The file couldn’t be opened")) == .missing)
    }

    /// An error of no known type is read from its words, and is at least a failure.
    @Test func anyOtherErrorFallsBackOnItsWords() {
        struct Opaque: Error, CustomStringConvertible { var description: String }
        #expect(ProblemCause.of(Opaque(description: "permission denied")) == .permission)
        #expect(ProblemCause.of(Opaque(description: "it broke")) == .exit)
    }

    @Test func theJournalCauseOfAProblem() {
        #expect(Problem(severity: .info, title: "Archived x: pull request merged").journalCause == .notice)
        #expect(Problem(severity: .error, title: "Sandbox of x is missing", cause: .missing).journalCause == .missing)
        #expect(Problem(severity: .error, title: "x", detail: "Could not resolve host").journalCause == .network)
        #expect(Problem(severity: .info, title: "x", cause: .persistence).journalCause == .persistence)
    }

    @Test func everyCauseSurvivesTheJournal() {
        for cause in ProblemCause.allCases {
            #expect(JournalEvent.token(cause.rawValue) == cause.rawValue)
        }
    }

    @Test func everyActionHasItsOwnUsageElement() {
        let kinds: [ProblemAction.Kind] = [.retryLaunch(ThreadID.generate()), .reprobeShell, .openSettings, .revealFile("/p"),
                                           .rescan(ScopeID.generate()), .locateScope(ScopeID.generate()), .rerunTaskSetup("t"),
                                           .retryTaskCleanup("t"), .reopenTask("t"), .dismiss]
        let elements = kinds.map { ProblemAction(title: "x", kind: $0).usageElement }
        #expect(Set(elements).count == kinds.count)
        #expect(elements.allSatisfy { JournalEvent.token($0) == $0 })
    }
}
