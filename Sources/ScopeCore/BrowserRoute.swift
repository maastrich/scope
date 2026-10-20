import CryptoKit
import Foundation

/// Which web links open in a task's Browser pane rather than in the system browser (Settings › General ›
/// Browser). The task's own servers come to the pane unless the user wants nothing there; the rest of the web
/// stays where the user is signed in, by default.
public enum WebLinkDestination: String, Codable, Sendable, CaseIterable {
    /// Only a port of the task's block (`SCOPE_PORT` and the nine after it).
    case taskServers
    /// Any `localhost`, `127.0.0.1` or `::1` address. The default.
    case localhost
    /// Every `http` and `https` link.
    case everything
    /// None: the pane opens only from its own button.
    case systemBrowser

    public var title: String {
        switch self {
        case .taskServers: "The task's servers"
        case .localhost: "Any localhost"
        case .everything: "Every web link"
        case .systemBrowser: "None — always the system browser"
        }
    }
}

/// Where a clicked web link goes (spec §7): a port chip, a ⌘-click on a URL a thread printed, a link in rendered
/// Markdown. Pure, so the whole table is tested.
///
/// - not `http`/`https` → the system, whatever the preference (`mailto:`, `vscode:`…);
/// - no task to show it in → the system: the pane is a task's;
/// - otherwise the preference decides, and ⌥ held while clicking sends the link to the other destination.
public enum BrowserRoute {
    public enum Destination: Equatable, Sendable {
        case pane, system
    }

    public static func destination(for url: URL, block: PortBlock?, preference: WebLinkDestination,
                                   hasTask: Bool, alternate: Bool = false) -> Destination {
        guard isWeb(url), hasTask else { return .system }
        let inPane: Bool
        switch preference {
        case .systemBrowser:
            inPane = false
        case .taskServers:
            inPane = isTaskServer(url, block: block)
        case .localhost:
            inPane = isLocal(url)
        case .everything:
            inPane = true
        }
        return inPane != alternate ? .pane : .system
    }

    public static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }

    /// The loopback: `localhost` and its subdomains (`app.localhost`), `127.x.x.x`, `::1`, `0.0.0.0`.
    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1"
            || host == "0.0.0.0"
    }

    /// A loopback address on a port of the task's block.
    public static func isTaskServer(_ url: URL, block: PortBlock?) -> Bool {
        guard let block, isLocal(url), let port = port(of: url) else { return false }
        return block.contains(port)
    }

    /// The explicit port, else the scheme's.
    public static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// Two URLs served by the same server: same scheme, port, and host — every loopback spelling counting as one,
    /// since `localhost:41000` and `127.0.0.1:41000` are the same dev server. What decides whether a link reuses a
    /// tab of the pane or opens one.
    public static func sameServer(_ a: URL, _ b: URL) -> Bool {
        guard isWeb(a), isWeb(b), a.scheme?.lowercased() == b.scheme?.lowercased(), port(of: a) == port(of: b) else {
            return false
        }
        if isLocal(a) && isLocal(b) { return true }
        return a.host?.lowercased() == b.host?.lowercased()
    }

    /// What the address bar typed means: a URL as is, `localhost:3000` or `:41000` on the loopback over http,
    /// anything else with a dot over https. `nil` for what reads as neither.
    public static func url(fromAddress text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if trimmed.hasPrefix(":"), let port = Int(trimmed.dropFirst()), (1...65535).contains(port) {
            return URL(string: "http://localhost:\(port)")
        }
        if let port = Int(trimmed), (1...65535).contains(port) {
            return URL(string: "http://localhost:\(port)")
        }
        if let url = URL(string: trimmed), isWeb(url) { return url }
        guard let guess = URL(string: "http://\(trimmed)"), let host = guess.host else { return nil }
        if isLocal(guess) { return guess }
        guard host.contains(".") else { return nil }
        return URL(string: "https://\(trimmed)")
    }

    /// The tab title of a page with no `<title>` yet: `:41000` for the loopback, the host otherwise.
    public static func shortTitle(_ url: URL) -> String {
        if isLocal(url), let port = port(of: url) { return ":\(port)" }
        return url.host ?? url.absoluteString
    }
}

/// The identifiers of the WebKit data stores the Browser pane uses (`WKWebsiteDataStore(forIdentifier:)`).
///
/// WebKit keeps them under `~/Library/WebKit/<bundle id>/`, outside `SCOPE_HOME`: two homes of one build would
/// share a store if its id were the scope's alone. So each id is a name-based UUID (v5) of the home *and* the
/// scope — or the task, for an agent's store — and stays the same across launches, which is what makes a user's
/// sign-in survive one.
public enum BrowserStoreID {
    /// The user's store for every task of a scope: their sign-ins, kept.
    public static func user(home: URL, scope: String) -> UUID {
        uuid5(name: "user|\(home.standardizedFileURL.path)|\(scope)")
    }

    /// An agent's store for one task, deleted with it.
    public static func agent(home: URL, task: String) -> UUID {
        uuid5(name: "agent|\(home.standardizedFileURL.path)|\(task)")
    }

    /// RFC 4122 §4.3 over a fixed namespace of Scope's own.
    static func uuid5(name: String) -> UUID {
        let namespace = UUID(uuidString: "6F1C3B2E-5A4D-4E8B-9C21-0B5E7A3D9F10")!
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(name.utf8))
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }
}

/// The tabs of every task's Browser pane: which tab each task shows, and which tab a link lands in. One tab per
/// server: a link to a server a tab already shows navigates that tab rather than piling up a new one.
public struct BrowserTabs: Sendable, Equatable {
    public struct Tab: Hashable, Sendable {
        public var id: String
        public var task: String
        /// Where the tab stands, as last reported by its page.
        public var url: URL?

        public init(id: String, task: String, url: URL?) {
            self.id = id
            self.task = task
            self.url = url
        }
    }

    public private(set) var tabs: [Tab] = []
    private var selection: [String: String] = [:]

    public init() {}

    public func tabs(of task: String) -> [Tab] { tabs.filter { $0.task == task } }

    public func tab(_ id: String) -> Tab? { tabs.first { $0.id == id } }

    /// The tab the task's pane shows: the one picked last, else the newest.
    public func selectedTab(of task: String) -> Tab? {
        let own = tabs(of: task)
        if let id = selection[task], let tab = own.first(where: { $0.id == id }) { return tab }
        return own.last
    }

    /// The task's tab already on `url`'s server, the shown one first.
    public func tab(of task: String, serving url: URL) -> Tab? {
        let own = tabs(of: task).filter { $0.url.map { BrowserRoute.sameServer($0, url) } ?? false }
        if let shown = selectedTab(of: task), own.contains(shown) { return shown }
        return own.first
    }

    public mutating func open(_ id: String, in task: String, url: URL?) {
        tabs.append(Tab(id: id, task: task, url: url))
        selection[task] = id
    }

    public mutating func select(_ id: String) {
        guard let tab = tab(id) else { return }
        selection[tab.task] = id
    }

    public mutating func update(_ id: String, url: URL?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].url = url
    }

    /// Closes a tab; the pane then shows the one to its right, else to its left.
    @discardableResult
    public mutating func close(_ id: String) -> Tab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let closed = tabs.remove(at: index)
        guard selection[closed.task] == id else { return closed }
        let after = tabs[index...].first { $0.task == closed.task }
        selection[closed.task] = (after ?? tabs(of: closed.task).last)?.id
        return closed
    }

    @discardableResult
    public mutating func closeAll(of task: String) -> [Tab] {
        let closed = tabs(of: task)
        tabs.removeAll { $0.task == task }
        selection[task] = nil
        return closed
    }
}
