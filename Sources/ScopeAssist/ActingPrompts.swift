import Foundation
import ScopeCore

/// What a trigger types into a thread: pure text, under test. Every message opens on a header saying it comes from
/// Scope and why, so the agent knows it is not the user and does not answer the user's last question again.
public enum ActingPrompts {
    /// `[Scope: automatic message, not from the user — connection lost]`
    public static func header(_ trigger: ActingTrigger) -> String {
        "[Scope: automatic message from Scope itself, not the user — \(trigger.title.lowercased())]"
    }

    static func envelope(_ trigger: ActingTrigger, _ body: String) -> String {
        "\(header(trigger))\n\(body)"
    }

    /// The error as Claude Code printed it, on one line and short; `nil` when it said nothing.
    static func quoted(_ error: String?) -> String? {
        guard let error else { return nil }
        let line = error.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    public static func connectionBack(error: String?) -> String {
        var text = "Your last turn stopped on a network error"
        if let quoted = quoted(error) { text += " (“\(quoted)”)" }
        text += """
        . The connection is back. Continue where you left off; if the step that was cut short may have half-run \
        (a push, a migration, a file write), check its state before repeating it.
        """
        return envelope(.connectionLost, text)
    }

    public static func afterWake(error: String?, restarted: Bool) -> String {
        var text = "The Mac slept and your last turn was cut short"
        if let quoted = quoted(error) { text += " (“\(quoted)”)" }
        if restarted { text += "; Scope restarted this session on the same conversation" }
        text += """
        . The network is back. Continue where you left off; check the state of anything that was mid-way before \
        repeating it.
        """
        return envelope(.wake, text)
    }

    public static func limitReset(resetsAt: Date?, throttled: Bool) -> String {
        let text: String
        if throttled {
            text = "Your last turn stopped because the API asked clients to slow down. Some time has passed: continue where you left off."
        } else if resetsAt != nil {
            text = "Your last turn stopped on the usage limit. The limit has reset: continue where you left off, on the same model."
        } else {
            text = """
            Your last turn stopped on the usage limit. Scope waited before retrying: continue where you left off, on \
            the same model. If the limit still holds, stop and say so in one line.
            """
        }
        return envelope(.usageLimit, text)
    }

    /// The pull request conflicts with its base, or a rebase Scope tried stopped. Merging the base in rather than
    /// rebasing: a thread's permissions refuse force pushes, and a message it cannot carry out is a loop.
    public static func conflicts(pullRequest number: Int?, base: String, branch: String, paths: [String],
                                 rebaseStopped: Bool) -> String {
        var text = rebaseStopped
            ? "Scope tried to rebase \(branch) on \(base) and stopped on conflicts."
            : "Pull request \(number.map { "#\($0)" } ?? "of this task") conflicts with \(base)."
        if !paths.isEmpty {
            text += " Conflicting: " + paths.prefix(8).joined(separator: ", ") + (paths.count > 8 ? " and \(paths.count - 8) more" : "") + "."
        }
        text += """
         Bring \(base) into \(branch): `git fetch origin`, then `git merge origin/\(base)`, resolve every conflict \
        keeping both sides where they do not overlap, regenerate anything generated, run the tests you touched one \
        file at a time, commit the merge and push \(branch). Do not force-push. Reply in one line when the branch is \
        mergeable, or say what blocks it.
        """
        return envelope(.conflicts, text)
    }

    /// A failed check as the message lists it.
    public struct FailedCheck: Sendable, Equatable {
        public var title: String
        public var url: URL?

        public init(title: String, url: URL?) {
            self.title = title
            self.url = url
        }
    }

    public static func checksFailed(pullRequest number: Int, head: String, checks: [FailedCheck]) -> String {
        let shown = checks.prefix(10).map { check in
            "- \(check.title)" + (check.url.map { " — \($0.absoluteString)" } ?? "")
        }
        var text = "Checks failed on pull request #\(number) (head \(head.prefix(7))):\n" + shown.joined(separator: "\n")
        if checks.count > 10 { text += "\n- and \(checks.count - 10) more" }
        text += """


        Read each failed job's log (`gh run view <run> --log-failed`). If a failure has nothing to do with this \
        change — a flaky job, a runner or network hiccup — rerun it once with `gh run rerun <run> --failed`. Otherwise \
        fix the cause, run the relevant tests locally one file at a time, commit and push. Reply in one line with what \
        you did.
        """
        return envelope(.ciFailed, text)
    }

    /// One comment to address.
    public struct ReviewComment: Sendable, Equatable {
        public var author: String
        /// `path:line` for a comment on the code, `nil` for one on the pull request.
        public var location: String?
        public var excerpt: String
        public var url: URL?
        /// `CHANGES_REQUESTED`, `COMMENTED`, … for a review's own body.
        public var state: String?

        public init(author: String, location: String? = nil, excerpt: String, url: URL? = nil, state: String? = nil) {
            self.author = author
            self.location = location
            self.excerpt = excerpt
            self.url = url
            self.state = state
        }
    }

    public static func review(pullRequest number: Int, comments: [ReviewComment]) -> String {
        let shown = comments.prefix(15).map { comment -> String in
            var line = "- \(comment.author)"
            if comment.state == "CHANGES_REQUESTED" { line += " (changes requested)" }
            if let location = comment.location { line += " on \(location)" }
            line += ": " + (quoted(comment.excerpt) ?? "")
            if let url = comment.url { line += " — \(url.absoluteString)" }
            return line
        }
        var text = "New review comments on pull request #\(number):\n" + shown.joined(separator: "\n")
        if comments.count > 15 { text += "\n- and \(comments.count - 15) more (`gh pr view \(number) --comments`)" }
        text += """


        Address each one that is right: change the code, run the relevant tests one file at a time, commit and push. \
        For one you disagree with, reply on the pull request saying why rather than changing the code. Reply here in \
        one line with what you did.
        """
        return envelope(.review, text)
    }

    public static func baseMoved(base: String, branch: String, files: [String], pullRequest number: Int?) -> String {
        var text = "\(base) moved and touches files this task changed"
        if !files.isEmpty {
            text += ": " + files.prefix(8).joined(separator: ", ") + (files.count > 8 ? " and \(files.count - 8) more" : "")
        }
        text += """
        . Nothing conflicts yet. Bring \(base) into \(branch) now, before it does: `git fetch origin`, \
        `git merge origin/\(base)`, run the tests you touched one file at a time, and push\
        \(number.map { " (pull request #\($0))" } ?? ""). Do not force-push. Reply in one line.
        """
        return envelope(.baseMoved, text)
    }

    public static func stuck(reason: String) -> String {
        var text = "Scope interrupted your turn: it seems to be going in circles"
        if let quoted = quoted(reason) { text += " — \(quoted)" }
        text += """
        . Stop repeating what did not work. Say in two lines what you tried and why it failed, then take a different \
        approach. If you are blocked on something only the user can give, ask for it and stop.
        """
        return envelope(.stuck, text)
    }
}
