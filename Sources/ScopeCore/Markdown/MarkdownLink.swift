import Foundation

/// What a link in rendered Markdown may do. The text comes from an agent — untrusted output — so a link either opens
/// in the browser (`http`, `https`, `mailto`), names a file the reading view resolves the way a terminal link is
/// resolved (`FileLinkResolver`), or does nothing at all.
public enum MarkdownLink: Sendable, Equatable {
    case web(URL)
    /// A path as written, with its `:line` or `#L12` suffix; `FileLinkResolver` finds the file.
    case file(String)
    /// `javascript:`, `data:`, an app's own scheme, …: shown as text, never followed.
    case refused

    /// The scheme the reading view gives a code span that names a file, so a click on it comes back as `.file`.
    public static let pathScheme = "scope-path"

    public static func classify(_ destination: String) -> MarkdownLink {
        let text = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .refused }
        if let scheme = scheme(of: text) {
            switch scheme {
            case "http", "https":
                guard let url = URL(string: text), url.host() != nil else { return .refused }
                return .web(url)
            case "mailto":
                return URL(string: text).map(MarkdownLink.web) ?? .refused
            case "file":
                return FileLinkResolver.parse(text) != nil ? .file(text) : .refused
            case pathScheme:
                let path = String(text.dropFirst(pathScheme.count + 1)).removingPercentEncoding ?? ""
                return path.isEmpty ? .refused : .file(path)
            default:
                return .refused
            }
        }
        // `#section`: an anchor in the page, which a reading view without anchors cannot follow.
        guard !text.hasPrefix("#") else { return .refused }
        // GitHub's `path#L12` becomes the terminal's `path:12`.
        var path = text
        if let hash = path.range(of: #"#L([0-9]+)(-L?[0-9]+)?$"#, options: .regularExpression) {
            let line = path[hash].dropFirst(2).prefix { $0.isNumber }
            path = String(path[..<hash.lowerBound]) + ":" + line
        }
        return .file(path.removingPercentEncoding ?? path)
    }

    /// The link a code span gets when its text reads as a file path — `Sources/App.swift:12`, `README.md`,
    /// `./scripts/build.sh` — and `nil` for code (`foo.bar()`, `x = 1`, `v1.2.3`, `--flag`).
    public static func pathLink(forCode code: String) -> URL? {
        guard looksLikePath(code) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":")
        guard let encoded = code.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(pathScheme):\(encoded)")
    }

    public static func looksLikePath(_ text: String) -> Bool {
        guard (2...300).contains(text.count), !text.contains(where: { $0.isWhitespace }),
              !text.hasPrefix("-"), scheme(of: text) == nil else { return false }
        guard !text.contains(where: { "()[]{}<>=;,\"'`$|*?!&@".contains($0) }) else { return false }
        var path = Substring(text)
        if let suffix = path.range(of: #"(:[0-9]+){1,2}$"#, options: .regularExpression) { path = path[..<suffix.lowerBound] }
        if path.hasPrefix("/") || path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("~/") {
            return path.count > 2
        }
        let name = path.split(separator: "/").last ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            // `Sources/ScopeCore`: a folder, worth trying only with a slash in it.
            return path.contains("/") && !path.hasSuffix("/") && path.first?.isLetter == true
        }
        // An extension is short and lower case, with a letter: `swift`, `md`, `ts`, `h`, `mp4` — not
        // `replyLimit` (a property) nor `3` (a version).
        let ext = name[name.index(after: dot)...]
        return (1...6).contains(ext.count) && ext.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber }
            && ext.contains(where: \.isLetter)
    }

    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        // `C:` would be a drive, `src/a.ts:12` a line: a scheme is letters first, then letters, digits, `+-.`.
        guard scheme.count >= 2, let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return nil }
        // `README.md:12` has a dot before its colon and digits after: a path with a line, not a scheme.
        if scheme.contains("."), text[text.index(after: colon)...].allSatisfy({ $0.isNumber || $0 == ":" }) { return nil }
        return scheme.lowercased()
    }
}
