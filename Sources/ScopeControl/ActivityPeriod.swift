import Foundation

/// A stretch of time a summary covers: `since` included, `until` excluded, both at midnight in the user's time zone.
///
/// Parsed from what a person types after `/scope-summary`. Weeks start on Monday (ISO 8601) whatever the locale says,
/// and "last week" is the calendar week before this one, not the last seven days — `last 7 days` says that. Day
/// boundaries come from the calendar, so a week across a daylight-saving change is still seven days.
public struct ActivityPeriod: Sendable, Equatable {
    public var label: String
    public var since: Date
    public var until: Date

    public init(label: String, since: Date, until: Date) {
        self.label = label
        self.since = since
        self.until = until
    }

    public func contains(_ date: Date) -> Bool { since <= date && date < until }

    /// What a period without words means.
    public static let defaultExpression = "last 7 days"

    public static let grammar = """
    today, yesterday, this week, last week, this month, last month, this year, last year,
    last <n> days|weeks|months (also "past <n> days", "7d", "2w"), 2026-10-01 (one day), 2026-10 (one month),
    2026-10-01..2026-10-14 (both days included; "to" works too), since 2026-10-01. Weeks start on Monday.
    """

    /// The calendar periods are counted in: ISO 8601 (Monday first) in `timeZone`.
    public static func calendar(_ timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `nil` when `expression` says nothing this grammar knows.
    public static func parse(_ expression: String?, now: Date = .now, calendar: Calendar = ActivityPeriod.calendar()) -> ActivityPeriod? {
        let raw = (expression ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let text = raw.isEmpty ? defaultExpression : raw.lowercased()
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        func period(_ since: Date, _ until: Date) -> ActivityPeriod {
            ActivityPeriod(label: raw.isEmpty ? defaultExpression : raw, since: since, until: until)
        }
        func start(of component: Calendar.Component, offset: Int) -> (Date, Date)? {
            guard let current = calendar.dateInterval(of: component, for: now),
                  let since = calendar.date(byAdding: component, value: offset, to: current.start),
                  let until = calendar.date(byAdding: component, value: 1, to: since) else { return nil }
            return (since, until)
        }

        switch text {
        case "today": return period(today, tomorrow)
        case "yesterday": return period(calendar.date(byAdding: .day, value: -1, to: today)!, today)
        default: break
        }
        let words = text.split(separator: " ").map(String.init)
        if words.count == 2, let offset = ["this": 0, "last": -1, "previous": -1][words[0]],
           let component = ["week": Calendar.Component.weekOfYear, "month": .month, "year": .year][words[1]],
           let (since, until) = start(of: component, offset: offset) {
            return period(since, until)
        }
        if let (count, unit) = rolling(words), count > 0 {
            let since: Date? = switch unit {
            case .day: calendar.date(byAdding: .day, value: 1 - count, to: today)
            case .weekOfYear: calendar.date(byAdding: .day, value: 1 - count * 7, to: today)
            default: calendar.date(byAdding: unit, value: -count, to: tomorrow)
            }
            return since.map { period($0, tomorrow) }
        }
        if words.count == 2, words[0] == "since", let (since, _) = day(words[1], calendar) {
            return period(since, max(tomorrow, calendar.date(byAdding: .day, value: 1, to: since)!))
        }
        if let range = text.range(of: "..") ?? text.range(of: " to ") {
            let left = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let (since, _) = day(left, calendar) else { return nil }
            if right.isEmpty { return period(since, max(tomorrow, calendar.date(byAdding: .day, value: 1, to: since)!)) }
            guard let (_, until) = day(right, calendar), since < until else { return nil }
            return period(since, until)
        }
        if let (since, until) = day(text, calendar) { return period(since, until) }
        return nil
    }

    /// `last 7 days`, `past 2 weeks`, `3 months`, `7d`, `2w`.
    private static func rolling(_ words: [String]) -> (Int, Calendar.Component)? {
        var words = words
        if let first = words.first, first == "last" || first == "past" { words.removeFirst() }
        let units: [String: Calendar.Component] = [
            "day": .day, "days": .day, "d": .day,
            "week": .weekOfYear, "weeks": .weekOfYear, "w": .weekOfYear,
            "month": .month, "months": .month, "m": .month,
        ]
        if words.count == 2, let count = Int(words[0]), let unit = units[words[1]] { return (count, unit) }
        if words.count == 1, let suffix = words[0].last, let unit = units[String(suffix)], let count = Int(words[0].dropLast()) {
            return (count, unit)
        }
        return nil
    }

    /// `2026-10-01` → that day; `2026-10` → that month. Both as [start, end).
    private static func day(_ text: String, _ calendar: Calendar) -> (Date, Date)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }), text.count == (parts.count == 3 ? 10 : 7) else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts.count == 3 ? parts[2] : 1)
        components.calendar = calendar
        guard components.isValidDate(in: calendar), let since = calendar.date(from: components),
              let until = calendar.date(byAdding: parts.count == 3 ? .day : .month, value: 1, to: since) else { return nil }
        return (since, until)
    }
}
