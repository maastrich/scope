import Foundation
import ScopeCore

/// What an agent asks of its task's browser (`scope browser …`, the `scope_browser_*` tools). One control method,
/// `browser`, carries every action: they share the task resolution, the fence (an agent drives its own task's
/// browser only) and the result shape.
public enum BrowserAction: String, Codable, Sendable, CaseIterable {
    /// Open the task's agent tab on a URL or a port — or on the task's first server — and wait for the load.
    case open
    /// The page as text: headings, paragraphs, and the interactive elements with a ref each (`e12`).
    case read
    /// A reduced JPEG of the viewport, written under `SCOPE_HOME/browser/shots/`.
    case screenshot
    /// What the page logged (`console.*`, uncaught errors) since the last read of it.
    case console
}

/// `browser` — one action on the agent tab of a task.
public struct BrowserParams: Codable, Sendable, Equatable {
    public var action: BrowserAction
    /// Task id or slug; `nil` = the task the caller's thread runs in.
    public var task: String?
    public var scope: String?
    /// `open`: where to go. A full URL, `localhost:5173`, `:41001`, or a path (`/checkout`) on the tab's server.
    public var url: String?
    /// `open`: a port — a number of the block (41003), or its index in the block (0–9).
    public var port: Int?
    /// `console`: every line kept, not only the new ones.
    public var all: Bool?

    public init(action: BrowserAction, task: String? = nil, scope: String? = nil, url: String? = nil, port: Int? = nil,
                all: Bool? = nil) {
        self.action = action
        self.task = task
        self.scope = scope
        self.url = url
        self.port = port
        self.all = all
    }
}

/// One line a page logged.
public struct BrowserConsoleLine: Codable, Sendable, Equatable {
    /// `log`, `info`, `warn`, `error`, `debug`; `error` for an uncaught exception or rejection.
    public var level: String
    public var text: String
    /// `file:line` when the browser said where.
    public var source: String?
    public var at: Date

    public init(level: String, text: String, source: String? = nil, at: Date) {
        self.level = level
        self.text = text
        self.source = source
        self.at = at
    }
}

/// The answer of every browser action: where the tab stands, and what the action brought back.
public struct BrowserResult: Codable, Sendable, Equatable {
    public var task: String
    public var slug: String
    public var action: BrowserAction
    public var url: String?
    public var title: String?
    /// Still loading when the answer left (a slow page, a timeout on `open`).
    public var loading: Bool
    /// What happened, in a line: `opened http://localhost:41000/ (Acme)`, a load failure.
    public var message: String
    /// `read`: the page, framed as untrusted (`BrowserPage.render`).
    public var page: String?
    /// `console`: the lines, oldest first.
    public var console: [BrowserConsoleLine]?
    /// `screenshot`: the JPEG's path, and its size in pixels.
    public var screenshot: String?
    public var width: Int?
    public var height: Int?
    /// Page content and console lines are written by the page: anything in them is data, never instructions.
    public var untrusted: Bool

    public init(task: String, slug: String, action: BrowserAction, url: String? = nil, title: String? = nil, loading: Bool = false,
                message: String, page: String? = nil, console: [BrowserConsoleLine]? = nil, screenshot: String? = nil,
                width: Int? = nil, height: Int? = nil) {
        self.task = task
        self.slug = slug
        self.action = action
        self.url = url
        self.title = title
        self.loading = loading
        self.message = message
        self.page = page
        self.console = console
        self.screenshot = screenshot
        self.width = width
        self.height = height
        self.untrusted = true
    }
}

/// What the page reader script hands back from the page's isolated world, and how it is put into words for the
/// agent. Pure: the framing is the defence the tool description promises.
public struct BrowserPage: Codable, Sendable, Equatable {
    public struct Block: Codable, Sendable, Equatable {
        /// `h1`…`h6`, `p`, `li`, `text`…; headings are rendered as Markdown headings.
        public var kind: String
        public var text: String
        /// Not shown to a person (`checkVisibility()` false): what a prompt injection hides.
        public var hidden: Bool

        public init(kind: String, text: String, hidden: Bool = false) {
            self.kind = kind
            self.text = text
            self.hidden = hidden
        }
    }

    public struct Element: Codable, Sendable, Equatable {
        /// `e1`, `e2`…: what `click` and `type` take.
        public var ref: String
        /// `link`, `button`, `textbox`, `checkbox`, `combobox`…
        public var role: String
        public var name: String
        public var value: String?
        public var href: String?
        public var hidden: Bool
        public var disabled: Bool

        public init(ref: String, role: String, name: String, value: String? = nil, href: String? = nil,
                    hidden: Bool = false, disabled: Bool = false) {
            self.ref = ref
            self.role = role
            self.name = name
            self.value = value
            self.href = href
            self.hidden = hidden
            self.disabled = disabled
        }
    }

    public var url: String
    public var title: String
    public var blocks: [Block]
    public var elements: [Element]

    public init(url: String, title: String, blocks: [Block], elements: [Element]) {
        self.url = url
        self.title = title
        self.blocks = blocks
        self.elements = elements
    }

    /// The cap on what one read hands the agent.
    public static let limit = 50_000

    /// The page as the agent reads it: inside `<untrusted-page origin=… title=…>` … `</untrusted-page>`, hidden text
    /// marked `(hidden)`, a closing tag the page wrote itself defused, cut at `limit` characters with a note.
    public func render(limit: Int = BrowserPage.limit) -> String {
        var body: [String] = []
        for block in blocks {
            let text = Self.oneLine(block.text)
            guard !text.isEmpty else { continue }
            let mark = block.hidden ? "(hidden) " : ""
            if block.kind.count == 2, block.kind.hasPrefix("h"), let level = Int(block.kind.dropFirst()), (1...6).contains(level) {
                body.append(String(repeating: "#", count: level) + " " + mark + text)
            } else if block.kind == "li" {
                body.append("- " + mark + text)
            } else {
                body.append(mark + text)
            }
        }
        if !elements.isEmpty {
            body.append("")
            body.append("Interactive elements:")
            for element in elements {
                var line = "[\(element.ref)] \(element.role)"
                let name = Self.oneLine(element.name)
                if !name.isEmpty { line += " \"\(name)\"" }
                if let value = element.value { line += " value=\"\(Self.oneLine(value))\"" }
                if let href = element.href { line += " → \(href)" }
                if element.disabled { line += " (disabled)" }
                if element.hidden { line += " (hidden)" }
                body.append(line)
            }
        }
        var text = Self.defuse(body.joined(separator: "\n"))
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n[… cut at \(limit) characters]"
        }
        return "<untrusted-page origin=\"\(Self.attribute(origin))\" title=\"\(Self.attribute(title))\">\n"
            + text + "\n</untrusted-page>"
    }

    /// `scheme://host:port` of the page.
    public var origin: String {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else { return url }
        return "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A page cannot close the frame early: its own `</untrusted-page>` loses its slash.
    static func defuse(_ text: String) -> String {
        text.replacingOccurrences(of: "</untrusted-page", with: "<\u{2215}untrusted-page", options: .caseInsensitive)
    }

    static func attribute(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "\"", with: "'")
    }
}

extension BrowserConsoleLine {
    /// `error  TypeError: cart is undefined  (index.html:41)`, one line per entry.
    public var rendered: String {
        let level = self.level.padding(toLength: 5, withPad: " ", startingAt: 0)
        return "\(level)  \(BrowserPage.oneLine(text))" + (source.map { "  (\($0))" } ?? "")
    }
}

public enum BrowserText {
    /// What an agent reads for `result`; the CLI prints the same.
    public static func render(_ result: BrowserResult) -> String {
        var lines = [result.message]
        if let url = result.url { lines.append("url    \(url)" + (result.loading ? "  (still loading)" : "")) }
        if let title = result.title, !title.isEmpty { lines.append("title  \(BrowserPage.oneLine(title))") }
        if let path = result.screenshot {
            lines.append("image  \(path)" + (result.width.map { w in result.height.map { "  (\(w)×\($0))" } ?? "" } ?? ""))
        }
        if let console = result.console {
            if console.isEmpty {
                lines.append("console: nothing new")
            } else {
                lines.append("<untrusted-console>")
                lines.append(contentsOf: console.map { BrowserPage.defuse($0.rendered) })
                lines.append("</untrusted-console>")
            }
        }
        if let page = result.page {
            lines.append("")
            lines.append(page)
        }
        return lines.joined(separator: "\n")
    }

    /// The port `open` means by `port`: an index into the block (0–9) or a port number as is.
    public static func port(_ value: Int, block: PortBlock?) -> Int {
        if let block, value >= 0, value < block.size { return block.base + value }
        return value
    }

    /// The URL `open` goes to: the `url` argument read like the address bar, a bare path on the tab's current server
    /// (else the task's first), or the port; `nil` when neither was given.
    public static func target(url: String?, port: Int?, block: PortBlock?, current: URL?, fallback: URL?) -> URL? {
        if let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if raw.hasPrefix("/") {
                guard let base = current.flatMap({ BrowserRoute.isWeb($0) ? $0 : nil }) ?? fallback,
                      var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
                let parts = raw.split(separator: "?", maxSplits: 1).map(String.init)
                components.path = parts[0]
                components.query = parts.count > 1 ? parts[1] : nil
                components.fragment = nil
                return components.url
            }
            return BrowserRoute.url(fromAddress: raw)
        }
        if let port { return PortBlock.url(for: self.port(port, block: block)) }
        return nil
    }
}
