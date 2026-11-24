import Foundation
import Testing
import ScopeCore
@testable import ScopeGit
import ScopeTasks

@Suite struct GhFailureTests {
    // What `gh` 2.x prints, cut from real runs; repository names and branches are made up.
    @Test(arguments: [
        ("error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com", GhFailure.offline),
        ("Post \"https://api.github.com/graphql\": dial tcp: lookup api.github.com: no such host", .offline),
        ("Post \"https://api.github.com/graphql\": read tcp 192.168.1.2:52000->140.82.121.6:443: read: connection reset by peer", .offline),
        ("To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable", .auth),
        ("HTTP 401: Bad credentials (https://api.github.com/graphql)\nTry authenticating with:  gh auth login", .auth),
        ("GraphQL: API rate limit exceeded for user ID 1234.", .rateLimit),
        ("HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again.", .rateLimit),
        ("GraphQL: Could not resolve to a Repository with the name 'acme/api'. (repository)", .notFound),
        ("GraphQL: Could not resolve to a PullRequest with the number of 4242. (repository.pullRequest)", .notFound),
        ("none of the git remotes configured for this repository point to a known GitHub host. To tell gh about a new GitHub host, please use `gh auth login`", .noRemote),
        ("failed to run git: fatal: not a git repository (or any of the parent directories): .git", .noRemote),
        ("HTTP 502: Bad Gateway (https://api.github.com/graphql)", .server),
        ("GraphQL: Something went wrong while executing your query. Please include `ABCD:1234` when reporting this issue.", .server),
    ])
    func stderrIsClassified(stderr: String, expected: GhFailure) {
        #expect(GhFailure.classify(exitCode: 1, stderr: stderr) == expected)
    }

    @Test func successIsNoFailure() {
        #expect(GhFailure.classify(exitCode: 0, stderr: "warning: something") == nil)
    }

    @Test func exitFourIsAuthWhateverItSaid() {
        #expect(GhFailure.classify(exitCode: 4, stderr: "") == .auth)
        #expect(GhFailure.classify(exitCode: 1, stderr: "") == .other)
        #expect(GhFailure.classify(exitCode: 1, stderr: "unknown flag: --frobnicate") == .other)
    }

    @Test func thrownErrorsAreClassified() {
        #expect(GhFailure.classify(error: SubprocessError.timedOut(after: .seconds(60))) == .timeout)
        #expect(GhFailure.classify(error: SubprocessError.launchFailed(GhFailure.missingDirectory)) == .missingCheckout)
        #expect(GhFailure.classify(error: SubprocessError.launchFailed("The file “sandbox” couldn’t be opened.")) == .missingCheckout)
        #expect(GhFailure.classify(error: GhError.notAuthenticated(message: "")) == .auth)
        #expect(GhFailure.classify(error: GhError.failed(command: "gh pr list", message: "error connecting to api.github.com")) == .offline)
        #expect(GhFailure.classify(error: GhError.invalidJSON(command: "gh pr list", message: "x")) == .invalidJSON)
        #expect(GhFailure.classify(error: GhError.noURL) == .invalidJSON)
        #expect(GhFailure.classify(error: GhError.notInstalled) == .notInstalled)
        #expect(GhFailure.classify(error: SubprocessError.launchFailed("The operation couldn’t be completed. Permission denied")) == .launchFailed)
        #expect(GhFailure.classify(error: CancellationError()) == .cancelled)
        #expect(GhFailure.classify(error: GhError.failed(command: "gh pr list", message: "unknown flag: --frobnicate")) == .other)
    }

    @Test func onlyFailuresThatSayNothingOfOneTaskAreGlobal() {
        #expect(GhFailure.offline.isGlobal && GhFailure.auth.isGlobal && GhFailure.rateLimit.isGlobal)
        #expect(!GhFailure.notFound.isGlobal && !GhFailure.missingCheckout.isGlobal && !GhFailure.noRemote.isGlobal)
        // Without `gh` every call fails the same way; a cancellation is no failure at all.
        #expect(GhFailure.notInstalled.isGlobal)
        #expect(!GhFailure.cancelled.isGlobal && !GhFailure.launchFailed.isGlobal && !GhFailure.invalidJSON.isGlobal)
    }

    /// The journal keeps the value as it is: every cause is a token, none is redacted.
    @Test func everyCauseSurvivesTheJournal() {
        for cause in GhFailure.allCases {
            #expect(JournalEvent.token(cause.rawValue) == cause.rawValue)
        }
    }

    @Test func theJournalOutcomeCarriesTheCauseNeverTheText() {
        let failed = ProcessResult(exitCode: 1, terminationReason: .exit, stdout: Data(),
                                   stderr: Data("GraphQL: Could not resolve to a Repository with the name 'acme/secret'.".utf8))
        let (outcome, cause) = GhClient.journalOutcome(.success(failed))
        #expect(outcome == "failed" && cause == .notFound)
        let none = ProcessResult(exitCode: 1, terminationReason: .exit, stdout: Data(), stderr: Data("no pull requests found for branch \"x\"".utf8))
        #expect(GhClient.journalOutcome(.success(none)).outcome == "none")
        #expect(GhClient.journalOutcome(.success(none)).cause == nil)
        let timedOut = GhClient.journalOutcome(.failure(SubprocessError.timedOut(after: .seconds(60))))
        #expect(timedOut.outcome == "timeout" && timedOut.cause == .timeout)
    }

    @Test func aMissingCheckoutFailsWithoutLaunchingGh() async {
        // `false` would fail too, but with exit 1: the missing directory must win before anything runs.
        let client = GhClient(executable: "/usr/bin/false")
        let gone = URL(fileURLWithPath: "/tmp/scope-no-such-dir-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await client.prList(in: gone)
            Issue.record("expected a failure")
        } catch {
            #expect(GhFailure.classify(error: error) == .missingCheckout)
        }
    }
}

/// 168 of the 257 `gh … failed other` of 03/11–18/11 lasted 0.00 s: the inspector's refresh loop is cancelled at every
/// task switch, and what `Subprocess.run` throws then is no failure of `gh`.
@Suite struct GhCancellationTests {
    /// What a `gh` call throws when the task running it is cancelled, mid-run or before it started.
    private func cancelledRun(alreadyCancelled: Bool) async -> any Error {
        let task = Task {
            if alreadyCancelled { try? await Task.sleep(for: .seconds(30)) }
            return try await Subprocess.run(executable: "/bin/sleep", arguments: ["30"], timeout: .seconds(60))
        }
        if !alreadyCancelled { try? await Task.sleep(for: .milliseconds(200)) }
        task.cancel()
        do {
            _ = try await task.value
            return SubprocessError.launchFailed("expected the run to throw")
        } catch {
            return error
        }
    }

    /// Before the fix both came out `.other`, journaled `failed`, and counted against the task's backoff.
    @Test(arguments: [false, true])
    func aCancelledRunIsSkippedNotFailed(alreadyCancelled: Bool) async {
        let error = await cancelledRun(alreadyCancelled: alreadyCancelled)
        #expect(error is CancellationError)
        #expect(GhFailure.classify(error: error) == .cancelled)
        let journaled = GhClient.journalOutcome(.failure(error))
        #expect(journaled.outcome == "skipped" && journaled.cause == .cancelled)
    }

    /// A cancelled pass never closes the gate, even repeated.
    @Test func aCancellationNeverBacksTheRefreshOff() {
        var gate = PullRequestRefreshGate()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<5 { gate.failed(.cancelled, at: now) }
        #expect(gate.allows(at: now))
        #expect(gate.lastCause == nil)
    }
}
