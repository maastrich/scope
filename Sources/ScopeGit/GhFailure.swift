import Foundation
import ScopeCore

/// Why a `gh` call failed, read from its exit code and stderr — what the event journal keeps instead of the text,
/// and what the pull request refresh backs off on.
///
/// Only the enum value leaves this file: stderr carries repository names, branches and URLs, which the journal never
/// writes (`JournalEvent.token`).
public enum GhFailure: String, Sendable, Equatable, CaseIterable {
    /// No route to GitHub: DNS, a refused or reset connection, no network at all.
    case offline
    /// Not logged in, a token refused or expired (`gh` exits 4 when it wants `gh auth login`).
    case auth
    /// GitHub's primary or secondary rate limit, or HTTP 429.
    case rateLimit = "rate-limit"
    /// The repository, pull request or branch does not exist, or is not visible to the account.
    case notFound = "not-found"
    /// The checkout has no remote `gh` recognises as GitHub, or is not a git repository.
    case noRemote = "no-remote"
    /// GitHub answered 5xx, or a GraphQL error it blames on itself.
    case server
    /// `gh` outlived the timeout Scope gave it.
    case timeout
    /// The directory `gh` was to run in is gone: an archived task's sandbox, a checkout moved away.
    case missingCheckout = "missing-checkout"
    /// Anything else.
    case other

    /// Whether the failure says nothing about one task in particular: the next call, whatever it asks, fails the same
    /// way. A refresh pass stops at the first one, and the whole refresh backs off rather than each task in turn.
    public var isGlobal: Bool {
        switch self {
        case .offline, .auth, .rateLimit, .server, .timeout: true
        case .notFound, .noRemote, .missingCheckout, .other: false
        }
    }

    /// From a finished `gh`: its exit code and stderr. `nil` when it succeeded.
    public static func classify(exitCode: Int32, stderr: String) -> GhFailure? {
        guard exitCode != 0 else { return nil }
        if let cause = classify(message: stderr) { return cause }
        // `gh` exits 4 when it needs `gh auth login`, whatever it printed.
        return exitCode == 4 ? .auth : .other
    }

    /// From stderr alone (`GhError.failed` keeps no exit code); `nil` when nothing matches.
    public static func classify(message: String) -> GhFailure? {
        let text = message.lowercased()
        guard !text.isEmpty else { return nil }
        // Most specific first: a rate limit answers 403, which would otherwise read as a refused token.
        let rules: [(GhFailure, [String])] = [
            (.rateLimit, ["rate limit", "http 429", "too many requests", "abuse detection"]),
            (.noRemote, ["none of the git remotes", "no git remotes found", "not a git repository",
                         "unable to determine base repository"]),
            (.auth, ["gh auth login", "http 401", "bad credentials", "authentication required", "not logged in",
                     "token has expired", "requires authentication", "saml", "must authenticate"]),
            (.offline, ["error connecting to", "could not resolve host", "no such host", "dial tcp", "network is unreachable",
                        "connection refused", "connection reset", "i/o timeout", "tls handshake timeout",
                        "check your internet connection", "the internet connection appears to be offline"]),
            (.notFound, ["could not resolve to a", "http 404", "not found", "no pull requests found"]),
            (.server, ["http 500", "http 502", "http 503", "http 504", "something went wrong", "server error"]),
            (.timeout, ["timed out", "timeout"]),
        ]
        for (cause, needles) in rules where needles.contains(where: text.contains) { return cause }
        return nil
    }

    /// What `GhClient` throws, without launching anything, when the directory it was to run in is gone.
    static let missingDirectory = "working directory does not exist"

    /// From what a `gh` call threw: `GhError`, or the `SubprocessError` of a call that never ran or ran too long.
    public static func classify(error: any Error) -> GhFailure {
        switch error {
        case GhError.notAuthenticated: return .auth
        case GhError.notInstalled: return .other
        case GhError.failed(_, let message): return classify(message: message) ?? .other
        case GhError.invalidJSON, GhError.noURL: return .other
        case SubprocessError.timedOut: return .timeout
        case SubprocessError.launchFailed(let message):
            // `Process.run()` refuses a working directory that does not exist before `gh` even starts.
            let text = message.lowercased()
            return [missingDirectory, "no such file", "doesn’t exist", "doesn't exist", "couldn’t be opened", "couldn't be opened"]
                .contains(where: text.contains) ? .missingCheckout : .other
        default: return .other
        }
    }
}
