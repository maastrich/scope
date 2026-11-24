import Foundation

extension SetupLog {
    /// What stands where a secret was.
    static let mask = "***"

    /// `text` with the credentials a command prints masked. A setup log is kept in the task record, shown in the
    /// reading column and quoted in a problem's detail; a `make` that echoes `pip install --index-url
    /// https://user:token@host/simple` put the token in all three.
    ///
    /// Only the secret goes: the scheme, the user, the host and the rest of the line stay, since the host is what
    /// says which index or registry refused. Masking twice changes nothing, so a record can be cleaned at every load.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                         withTemplate: rule.template)
        }
        return result
    }

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            // The patterns are literals of this file: one that does not compile is a bug the tests catch.
            regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    private static let rules: [Rule] = [
        // scheme://user:secret@host. The secret stops at what a URL would percent-encode there, so a port followed
        // by a path or a query holding an `@` (`http://localhost:3000/?to=a@b`) is not taken for one.
        Rule(#"\b([a-z][a-z0-9+.-]*://[^\s/:@?#'"<>]*):[^\s/@?#'"<>]+@"#, "$1:\(mask)@", options: .caseInsensitive),
        // scheme://token@host: a userinfo with no password is the token itself when it is long (`https://<token>@
        // pypi.fury.io`), a plain user name when it is short (`ssh://git@github.com`).
        Rule(#"\b([a-z][a-z0-9+.-]*://)[^\s/:@?#'"<>]{20,}@"#, "$1\(mask)@", options: .caseInsensitive),
        // JWT (three segments) and JWE (five, some of them empty).
        Rule(#"\beyJ[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*){2,4}"#, "eyJ\(mask)"),
        // GitHub tokens, classic and fine-grained, and npm's.
        Rule(#"\b(gh[pousr]_|github_pat_|npm_)[A-Za-z0-9_]{20,}"#, "$1\(mask)"),
        // .npmrc: `//registry.npmjs.org/:_authToken=…`, and the older `_auth` / `_password`.
        Rule(#"(_auth(?:Token)?|_password)([ \t]*=[ \t]*["']?)[^\s"']+"#, "$1$2\(mask)"),
        // An Authorization header, as curl -v or a failing client prints it; then a bearer token on its own.
        Rule(#"\b(authorization["']?[ \t]*[:=][ \t]*["']?(?:bearer|basic|token)[ \t]+)[^\s"']+"#, "$1\(mask)",
             options: .caseInsensitive),
        Rule(#"\b(bearer[ \t]+)[A-Za-z0-9._~+/=-]{16,}"#, "$1\(mask)", options: .caseInsensitive),
        // .netrc, on one line or one field per line.
        Rule(#"\b(login\s+\S+\s+password\s+)\S+"#, "$1\(mask)"),
    ]
}
