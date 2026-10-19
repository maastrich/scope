import Foundation
import ScopeCore

/// `scope usage [period]` — what the user did in Scope's own interface over a period, read from the local usage log.
public struct UsageParams: Codable, Sendable, Equatable {
    /// `ActivityPeriod.grammar`; `nil` = `ActivityPeriod.defaultExpression`.
    public var period: String?
    /// One area only (`sidebar`, `inspector`, `command`, `control`, …).
    public var area: String?
    /// Rows per list; `nil` = `UsageReport.defaultLimit`.
    public var limit: Int?

    public init(period: String? = nil, area: String? = nil, limit: Int? = nil) {
        self.period = period
        self.area = area
        self.limit = limit
    }
}

public struct UsageResult: Codable, Sendable, Equatable {
    public struct Period: Codable, Sendable, Equatable {
        public var label: String
        public var since: Date
        /// Excluded.
        public var until: Date
        public var timeZone: String
    }

    /// One element and how often it was used, now and in the period just before.
    public struct Element: Codable, Sendable, Equatable {
        public var id: String
        public var label: String?
        public var area: String
        public var count: Int
        public var previous: Int
    }

    public struct Area: Codable, Sendable, Equatable {
        public var area: String
        public var count: Int
        public var previous: Int
        /// Its most used elements.
        public var top: [Element]
    }

    /// How one command was reached. `mouse` counts the clicks on a control logged under the command's id.
    public struct Command: Codable, Sendable, Equatable {
        public var id: String
        public var label: String?
        public var keyboard: Int
        public var menu: Int
        public var palette: Int
        public var mouse: Int
        public var total: Int { keyboard + menu + palette + mouse }

        enum CodingKeys: String, CodingKey { case id, label, keyboard, menu, palette, mouse, total }

        public init(id: String, label: String?, keyboard: Int = 0, menu: Int = 0, palette: Int = 0, mouse: Int = 0) {
            self.id = id
            self.label = label
            self.keyboard = keyboard
            self.menu = menu
            self.palette = palette
            self.mouse = mouse
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            keyboard = try container.decode(Int.self, forKey: .keyboard)
            menu = try container.decode(Int.self, forKey: .menu)
            palette = try container.decode(Int.self, forKey: .palette)
            mouse = try container.decode(Int.self, forKey: .mouse)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encode(keyboard, forKey: .keyboard)
            try container.encode(menu, forKey: .menu)
            try container.encode(palette, forKey: .palette)
            try container.encode(mouse, forKey: .mouse)
            try container.encode(total, forKey: .total)
        }
    }

    /// A control method (`thread.new`), split by who called it.
    public struct Control: Codable, Sendable, Equatable {
        public var method: String
        public var user: Int
        public var agent: Int
    }

    /// A sheet, a section or a panel: how often it was opened and how long it was looked at. `seconds` only adds up
    /// the runs the screen-time clock counted (`UsageEvent.isTimedView`): an opening from before it is counted in
    /// `opens` and nowhere else.
    public struct View: Codable, Sendable, Equatable {
        public var id: String
        public var label: String?
        public var opens: Int
        public var seconds: Double
    }

    /// Something whose use moved the most against the previous period.
    public struct Trend: Codable, Sendable, Equatable {
        public var id: String
        public var label: String?
        public var count: Int
        public var previous: Int
    }

    public var period: Period
    /// The same length of time, just before `period`.
    public var previousPeriod: Period
    /// Events in the period, and in the one before.
    public var total: Int
    public var previousTotal: Int
    /// `false` when the user turned recording off in Settings: whatever is below stops when they did.
    public var recording: Bool
    /// The oldest event on disk: before it, nothing was recorded.
    public var historySince: Date?
    /// The oldest `view` event timed by the screen-time clock: from it, `views[].seconds` can be trusted. `nil` when
    /// there is none yet.
    public var screenTimeSince: Date?
    public var top: [Element]
    public var areas: [Area]
    /// Registered elements nobody used in the period, by area then id. Elements never drawn are not in the registry
    /// and cannot be here.
    public var neverUsed: [Element]
    public var commands: [Command]
    public var control: [Control]
    public var views: [View]
    /// Preference keys changed, with how often.
    public var settings: [Element]
    public var rising: [Trend]
    public var falling: [Trend]
    public var limits: [String]
}

/// Builds a `UsageResult` from the events of two periods and the registry. Pure.
public enum UsageReport {
    public static let defaultLimit = 20

    public static let fixedLimits = [
        "Only what the app instruments is counted: a control drawn by the app, a menu command, a palette row, a notification action, a CLI or MCP call. Typing in a terminal is never recorded.",
        "A button without its own usage id is counted under its area (`<area>.button`): the area is right, the button is not named.",
        "Buttons pressed with the keyboard (Return on a default button, Space on a focused one) are not counted as clicks; menu shortcuts are, as `keyboard`.",
        "`neverUsed` lists elements the app has drawn at least once since recording began; one never shown is in neither list.",
        "Time on screen counts only while Scope is frontmost, one of its windows is visible, the session is unlocked and you touched the keyboard or the mouse in the last two minutes.",
    ]

    /// The period before `period`, of the same length.
    public static func previous(of period: ActivityPeriod) -> ActivityPeriod {
        let span = period.until.timeIntervalSince(period.since)
        return ActivityPeriod(label: "previous", since: period.since.addingTimeInterval(-span), until: period.since)
    }

    public static func build(
        period: ActivityPeriod, timeZone: TimeZone = .current,
        events: [UsageEvent], previousEvents: [UsageEvent], registry: UsageRegistry,
        recording: Bool = true, historySince: Date? = nil, screenTimeSince: Date? = nil, area: String? = nil,
        limit: Int = defaultLimit
    ) -> UsageResult {
        let previousPeriod = previous(of: period)
        let current = events.filter { period.contains($0.at) && (area == nil || $0.area == area) }
        let before = previousEvents.filter { previousPeriod.contains($0.at) && (area == nil || $0.area == area) }
        func label(_ id: String) -> String? { registry.elements[id]?.label }
        func areaOf(_ id: String) -> String { registry.elements[id]?.area ?? UsageEvent.area(of: id) }

        // A `view` counts as one use per opening; everything else per event.
        let counts = tally(current)
        let previousCounts = tally(before)
        func element(_ id: String) -> UsageResult.Element {
            .init(id: id, label: label(id), area: areaOf(id), count: counts[id] ?? 0, previous: previousCounts[id] ?? 0)
        }
        let ranked = counts.keys.map(element).sorted(by: byCount)

        var areas: [String: (count: Int, previous: Int, elements: [UsageResult.Element])] = [:]
        for item in ranked { areas[item.area, default: (0, 0, [])].count += item.count; areas[item.area]!.elements.append(item) }
        for (id, count) in previousCounts { areas[areaOf(id), default: (0, 0, [])].previous += count }
        let areaRows = areas.map { key, value in
            UsageResult.Area(area: key, count: value.count, previous: value.previous, top: Array(value.elements.prefix(5)))
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.area < $1.area }

        let neverUsed = registry.elements.values
            .filter { counts[$0.id] == nil && (area == nil || $0.area == area) }
            .map { UsageResult.Element(id: $0.id, label: $0.label, area: $0.area, count: 0, previous: previousCounts[$0.id] ?? 0) }
            .sorted { $0.area != $1.area ? $0.area < $1.area : $0.id < $1.id }

        var commands: [String: UsageResult.Command] = [:]
        for event in current where event.id.hasPrefix("command.") {
            var row = commands[event.id] ?? .init(id: event.id, label: label(event.id))
            switch event.kind {
            case .shortcut: row.keyboard += 1
            case .menu: row.menu += 1
            case .palette: row.palette += 1
            case .click: row.mouse += 1
            default: continue
            }
            commands[event.id] = row
        }

        var control: [String: UsageResult.Control] = [:]
        for event in current where event.kind == .control {
            let method = event.id.hasPrefix("control.") ? String(event.id.dropFirst("control.".count)) : event.id
            var row = control[method] ?? .init(method: method, user: 0, agent: 0)
            if event.source == .agent { row.agent += 1 } else { row.user += 1 }
            control[method] = row
        }

        var views: [String: UsageResult.View] = [:]
        for event in current where event.kind == .view {
            var row = views[event.id] ?? .init(id: event.id, label: label(event.id), opens: 0, seconds: 0)
            // A run after a pause is the same opening; a duration from before the clock could be a night.
            if event.context != UsageEvent.resumedViewContext { row.opens += 1 }
            if event.isTimedView { row.seconds += max(0, event.duration ?? 0) }
            views[event.id] = row
        }

        let settings = current.filter { $0.kind == .setting }.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
            .map { UsageResult.Element(id: $0.key, label: label($0.key), area: areaOf($0.key), count: $0.value,
                                       previous: previousCounts[$0.key] ?? 0) }
            .sorted(by: byCount)

        let movers = Set(counts.keys).union(previousCounts.keys).map {
            UsageResult.Trend(id: $0, label: label($0), count: counts[$0] ?? 0, previous: previousCounts[$0] ?? 0)
        }
        let rising = movers.filter { $0.count > $0.previous }
            .sorted { ($0.count - $0.previous, $1.id) > ($1.count - $1.previous, $0.id) }
        let falling = movers.filter { $0.count < $0.previous }
            .sorted { ($0.previous - $0.count, $1.id) > ($1.previous - $1.count, $0.id) }

        var limits = fixedLimits
        if let screenTimeSince, screenTimeSince > period.since {
            limits.insert("Time on screen is measured since \(screenTimeSince.formatted(.iso8601.year().month().day())): openings before it are counted, their durations are not.", at: 0)
        } else if screenTimeSince == nil, current.contains(where: { $0.kind == .view }) {
            limits.insert("Time on screen is not measured yet: openings are counted, their durations are not.", at: 0)
        }
        if !recording { limits.insert("Recording is off (Settings ▸ General ▸ Usage): nothing after it was turned off is counted.", at: 0) }
        if let historySince, historySince > period.since {
            limits.insert("Recording began \(historySince.formatted(.iso8601.year().month().day())), inside this period: anything before is unknown, not unused.", at: 0)
        } else if historySince == nil {
            limits.insert("Nothing has been recorded yet.", at: 0)
        }

        return UsageResult(
            period: render(period, timeZone), previousPeriod: render(previousPeriod, timeZone),
            total: current.count, previousTotal: before.count, recording: recording, historySince: historySince,
            screenTimeSince: screenTimeSince,
            top: Array(ranked.prefix(limit)), areas: areaRows, neverUsed: neverUsed,
            commands: commands.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id },
            control: control.values.sorted { ($0.user + $0.agent, $1.method) > ($1.user + $1.agent, $0.method) },
            views: views.values.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id },
            settings: settings,
            rising: Array(rising.prefix(limit / 2 > 0 ? limit / 2 : 1)),
            falling: Array(falling.prefix(limit / 2 > 0 ? limit / 2 : 1)),
            limits: limits
        )
    }

    static func tally(_ events: [UsageEvent]) -> [String: Int] {
        events.reduce(into: [:]) { $0[$1.id, default: 0] += 1 }
    }

    private static func byCount(_ lhs: UsageResult.Element, _ rhs: UsageResult.Element) -> Bool {
        lhs.count != rhs.count ? lhs.count > rhs.count : lhs.id < rhs.id
    }

    private static func render(_ period: ActivityPeriod, _ timeZone: TimeZone) -> UsageResult.Period {
        .init(label: period.label, since: period.since, until: period.until, timeZone: timeZone.identifier)
    }
}
