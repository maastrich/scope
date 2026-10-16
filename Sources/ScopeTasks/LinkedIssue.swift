import Foundation
import ScopeGit

/// The GitHub issue a task was opened from (`scope task new --issue 123`, or an issue the prompt asks to work on).
/// Only what the task keeps: the number, the page, the title. The body and the labels went into the brief.
public struct LinkedIssue: Codable, Sendable, Equatable, Hashable {
    public var number: Int
    public var url: URL
    public var title: String

    public init(number: Int, url: URL, title: String) {
        self.number = number
        self.url = url
        self.title = title
    }

    public init(_ issue: Issue) {
        self.init(number: issue.number, url: issue.url, title: issue.title)
    }

    /// `#123`
    public var label: String { "#\(number)" }
}

/// How an issue becomes a brief: its title, body and labels first, between markers, then what the user asked.
public enum IssueBrief {
    /// Characters of the body kept; an issue is a conversation opener, not a specification.
    public static let bodyLimit = 6_000

    /// The brief of a task opened from `issue`: the issue, then `request` when it says more than the reference.
    public static func prefixed(_ request: String, with issue: Issue) -> String {
        var lines = ["# Issue \(issue.label): \(issue.title)", "", issue.url.absoluteString]
        if !issue.labels.isEmpty { lines.append("Labels: " + issue.labels.joined(separator: ", ")) }
        let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            lines.append("")
            lines.append(body.count > bodyLimit ? String(body.prefix(bodyLimit)) + "…" : body)
        }
        lines.append("")
        lines.append("Reference the issue from the pull request that closes it (`Closes \(issue.label)`).")
        let rest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty, !isOnlyTheReference(rest, issue: issue) {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append(rest)
        }
        return lines.joined(separator: "\n")
    }

    /// `#123`, its URL, `123`: a request that says nothing the issue does not.
    static func isOnlyTheReference(_ request: String, issue: Issue) -> Bool {
        let bare = request.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return bare == String(issue.number) || bare == issue.url.absoluteString
            || bare.lowercased() == "\(issue.repository ?? "")#\(issue.number)".lowercased()
    }

    /// `Fix: <title>`-style task name from an issue: the title, cut as a task title is.
    public static func title(for issue: Issue) -> String {
        TaskProposer.cleanTitle(issue.title) ?? "Issue \(issue.label)"
    }
}
