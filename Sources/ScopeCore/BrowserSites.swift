import Foundation

/// Where an agent's browser may go (Settings ▸ Automation ▸ Browser).
public enum BrowserSites: String, Codable, Sendable, CaseIterable {
    /// The ports of the task's block, on the loopback.
    case taskPorts
    /// Any loopback address.
    case localhost
    /// Anywhere. The default: the agent's store is empty, so a page holds nothing of the user's.
    case any

    public var title: String {
        switch self {
        case .taskPorts: "The task's own ports"
        case .localhost: "localhost only"
        case .any: "Anywhere"
        }
    }
}

/// What an agent's browser may load, as a pure rule: the check `open` makes before navigating, and the content rule
/// list WebKit enforces on every navigation and subresource after it (`WKContentRuleList`, measured to block both).
public enum BrowserSitePolicy {
    /// `Example.COM.` → `example.com`; a pasted URL keeps its host; blanks and duplicates go.
    public static func normalized(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        return hosts.compactMap { raw -> String? in
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if text.contains("://"), let host = URL(string: text)?.host { text = host }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "./*"))
            guard !text.isEmpty, !text.contains(" "), seen.insert(text).inserted else { return nil }
            return text
        }
    }

    /// `host` is `entry` or one of its subdomains.
    public static func host(_ host: String, isUnder entry: String) -> Bool {
        let host = host.lowercased()
        return host == entry || host.hasSuffix("." + entry)
    }

    /// Why `url` is refused to an agent's browser, or `nil` when it may go there.
    public static func refusal(for url: URL, sites: BrowserSites, block: PortBlock?, blocked: [String]) -> String? {
        guard BrowserRoute.isWeb(url), let host = url.host?.lowercased() else { return nil }
        if let entry = blocked.first(where: { self.host(host, isUnder: $0) }) {
            return "\(host) is blocked for agents" + (entry == host ? "" : " (\(entry))")
        }
        switch sites {
        case .any:
            return nil
        case .localhost:
            return BrowserRoute.isLocal(url) ? nil : "agents' browsers stay on localhost (Settings ▸ Automation ▸ Browser)"
        case .taskPorts:
            return BrowserRoute.isTaskServer(url, block: block) ? nil
                : "agents' browsers stay on the task's ports (Settings ▸ Automation ▸ Browser)"
        }
    }

    /// The WebKit content rule list for an agent's tab: everything blocked but what `sites` allows, then the blocked
    /// hosts on top. `nil` when nothing is restricted. WebKit's `url-filter` has no `|`, so each alternative is a rule
    /// of its own; it sees URLs normalized, with a `/` after the host.
    public static func contentRules(sites: BrowserSites, block: PortBlock?, blocked: [String]) -> String? {
        var rules: [[String: Any]] = []
        let hosts = [#"localhost"#, #"127\.0\.0\.1"#, #"\[::1\]"#, #"[^/:]+\.localhost"#]
        switch sites {
        case .any:
            break
        case .localhost:
            rules.append(blockAll)
            rules += hosts.map { allow(#"^https?://"# + $0 + "[:/]") }
        case .taskPorts:
            rules.append(blockAll)
            for port in block?.range ?? 0..<0 {
                rules += hosts.map { allow(#"^https?://"# + $0 + ":\(port)/") }
            }
        }
        // Pages the browser makes itself (about:blank, a data: image) are never the problem.
        if sites != .any { rules += ["about:", "data:", "blob:"].map { allow("^" + $0) } }
        for host in blocked {
            let escaped = NSRegularExpression.escapedPattern(for: host)
            rules.append(["trigger": ["url-filter": #"^[a-z]+://([^/:]*\.)?"# + escaped + "[:/]"], "action": ["type": "block"]])
        }
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static var blockAll: [String: Any] { ["trigger": ["url-filter": ".*"], "action": ["type": "block"]] }

    private static func allow(_ filter: String) -> [String: Any] {
        ["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]]
    }
}
