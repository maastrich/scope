import Foundation

/// One thing the user did in Scope, as `SCOPE_HOME/usage/usage-YYYY-MM.jsonl` keeps it: one JSON object per line.
///
/// What an event may hold is the whole privacy story, so it is narrow on purpose: the id of a control, a command or a
/// control method, never its label when the label can carry data (a thread title, a path, a branch); the scope as its
/// UUID, never its name or folder; for a setting, the key that changed and not the value. Nothing in here leaves the Mac.
public struct UsageEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A control drawn by the app was clicked: a button, a menu trigger, a picker, a toggle, a sidebar row.
        case click
        /// A menu command reached through its key equivalent.
        case shortcut
        /// A menu command picked from the menu bar.
        case menu
        /// A command palette row was chosen.
        case palette
        /// A notification's banner or one of its actions.
        case notification
        /// A CLI or MCP request; `source` says whether the user's terminal or an agent made it.
        case control
        /// A sheet, an inspector section or a panel was on screen; `duration` is how long. Since the screen-time clock
        /// (`ScreenTimeClock`) one event is one counted run: `context` is `active` for the first run of an opening,
        /// `resumed` for the runs after a pause. Events without either were timed from appear to disappear, whatever
        /// the person was doing, and the report ignores their durations.
        case view
        /// A preference changed; `id` is its key, the value is never recorded.
        case setting
        /// The assistant classified something; `id` is `assist.<job>.<verdict>` and `context` the tier that answered
        /// (`on-device`, `haiku`) or `false-positive` for a verdict the user overruled. Never the text it read.
        case assist
    }

    public enum Source: String, Codable, Sendable, CaseIterable {
        case mouse, keyboard, menu, palette, notification
        /// A control request from a terminal the user typed in (no thread) or from the user's own thread.
        case user
        /// A control request from an agent running in a thread, or an external agent.
        case agent
        /// The app did it on its own (a section open at launch, a view closed at quit).
        case app
    }

    public var at: Date
    public var kind: Kind
    /// Dotted, lowercase: `<area>.<element>` (`inspector.delta.refresh`, `command.new-thread`, `control.thread.new`).
    /// The first component is the area the report groups by.
    public var id: String
    public var source: Source
    /// The scope's UUID, when the event happened in one.
    public var scope: String?
    /// A short qualifier from a closed set (`cli`, `mcp`, `banner`) — never free text.
    public var context: String?
    /// Seconds a `view` stayed on screen.
    public var duration: Double?

    public init(at: Date = .now, kind: Kind, id: String, source: Source, scope: String? = nil,
                context: String? = nil, duration: Double? = nil) {
        self.at = at
        self.kind = kind
        self.id = id
        self.source = source
        self.scope = scope
        self.context = context
        self.duration = duration
    }

    /// `context` of a `view` event counted by the screen-time clock: the first run of an opening.
    public static let activeViewContext = "active"
    /// `context` of a `view` event counted after a pause of the same opening: a run, not another opening.
    public static let resumedViewContext = "resumed"

    /// `true` for a `view` event whose duration was counted by the screen-time clock, so it can be trusted.
    public var isTimedView: Bool {
        kind == .view && (context == Self.activeViewContext || context == Self.resumedViewContext)
    }

    /// The area of `id`: its first dotted component.
    public var area: String { UsageEvent.area(of: id) }

    public static func area(of id: String) -> String {
        id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? id
    }

    /// One line of the log, without its newline. Keys sorted and dates in ISO 8601 so a line reads the same every time.
    public func line() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(line: some DataProtocol) -> UsageEvent? {
        try? decoder.decode(UsageEvent.self, from: Data(line))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            if let date = try? Date(text, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
        }
        return decoder
    }()
}

/// What a usage id stands for, so the report can name it and, above all, list what was *never* used: the log only
/// holds what happened, the registry holds what could have.
public struct UsageElement: Codable, Sendable, Equatable {
    public var id: String
    /// What the user sees: a button's title, a command's menu title. Static text only.
    public var label: String
    public var area: String

    public init(id: String, label: String, area: String? = nil) {
        self.id = id
        self.label = label
        self.area = area ?? UsageEvent.area(of: id)
    }
}

/// `SCOPE_HOME/usage/registry.json`: every element the app has instrumented, keyed by id. Controls register the first
/// time they are drawn, commands and palette actions from a static list at launch; an entry is never removed, since
/// "drawn once, months ago, never clicked" is exactly the answer it is there for.
public struct UsageRegistry: Codable, Sendable, Equatable {
    public var elements: [String: UsageElement]

    public init(elements: [String: UsageElement] = [:]) {
        self.elements = elements
    }

    /// Adds what is new and refreshes labels that changed. `true` when anything did.
    @discardableResult
    public mutating func merge(_ incoming: [UsageElement]) -> Bool {
        var changed = false
        for element in incoming where elements[element.id] != element {
            // A derived label never overwrites an explicit one: an element registered with a better name keeps it.
            if let existing = elements[element.id], existing.label != existing.id, element.label == element.id { continue }
            elements[element.id] = element
            changed = true
        }
        return changed
    }
}

/// Turns what the app knows about a control into an id that can be logged: lowercase, dotted, hyphenated words.
public enum UsageID {
    /// `"New Thread…"` → `new-thread`; `"arrow.clockwise"` → `arrow-clockwise`. Anything not a letter or digit splits
    /// words, so an id never holds a slash or a dot it did not choose.
    public static func slug(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: "-")
    }

    /// Joins already-slugged parts with dots, dropping empty ones.
    public static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ".")
    }

    /// Palette action ids that end in data (a repository, a topic, a task id), longest first so `editor-sandbox-`
    /// wins over `editor-`. The tail is cut, the prefix is the command.
    static let dynamicPaletteActions = ["editor-sandbox-", "add-repo-", "task-topic-", "pr-task-", "editor-", "restore-", "send-"]
    /// Action ids that look like a dynamic one and are not.
    static let staticPaletteActions: Set<String> = ["editor-task", "restore-task", "send-to-thread"]

    /// The id a palette row is logged under. Action rows keep their id with its dynamic tail cut (`add-repo-<repo>` is
    /// `command.add-repo`); a row that *is* data — a thread, a task, a file, a scope, a pull request — logs its section
    /// only, since its id is a path or a record id. An action id this does not know and that looks like data (a digit,
    /// a slash) is logged as `command.other` rather than risk it.
    public static func palette(itemID: String, section: String, actionSection: Bool) -> String {
        guard actionSection else { return join("palette", slug(section)) }
        if !staticPaletteActions.contains(itemID), let prefix = dynamicPaletteActions.first(where: { itemID.hasPrefix($0) && itemID.count > $0.count }) {
            return join("command", slug(String(prefix.dropLast())))
        }
        let plain = itemID.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || $0 == "-" }
        return join("command", plain && itemID.count <= 40 ? itemID : "other")
    }

    /// The top-level keys whose values differ between two encodable values — which preferences a change touched,
    /// without saying what they became.
    public static func changedKeys<Value: Encodable>(_ before: Value, _ after: Value) -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let old = try? encoder.encode(before), let new = try? encoder.encode(after),
              let lhs = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
              let rhs = try? JSONSerialization.jsonObject(with: new) as? [String: Any] else { return [] }
        return Set(lhs.keys).union(rhs.keys).sorted().filter { key in
            let left = lhs[key].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
            let right = rhs[key].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
            return left != right
        }
    }
}
