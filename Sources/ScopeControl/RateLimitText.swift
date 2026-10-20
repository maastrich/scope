import Foundation
import ScopeAdapters

/// The subscription's limits as `scope ping`, `scope list` and the MCP tools report them: one line per window, the
/// tightest named, so an agent can slow down near the ceiling without parsing the status line itself.
public struct RateLimitsSummary: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        /// `five_hour`, `seven_day`, …
        public var id: String
        /// `5-hour session`, `Weekly`, …
        public var label: String
        /// 0–100, above once exceeded.
        public var usedPercentage: Double
        public var resetsAt: Date?
        /// Seconds until the reset, `nil` when unknown or already past.
        public var resetsIn: Int?
        /// `calm`, `watch`, `tight`, `exhausted` (`RateLimitLevel`).
        public var level: String

        public init(id: String, label: String, usedPercentage: Double, resetsAt: Date?, resetsIn: Int?, level: String) {
            self.id = id
            self.label = label
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
            self.resetsIn = resetsIn
            self.level = level
        }
    }

    /// `Max 20×`, `Pro`, … when Claude Code's account file says; absent otherwise.
    public var plan: String?
    /// Windows still running, tightest first.
    public var windows: [Window]
    /// The id of the window nearest its ceiling.
    public var tightest: String?
    /// When Claude Code reported these.
    public var reportedAt: Date
    /// `true` when the report is older than `RateLimits.staleAfter`: usage elsewhere may not show yet.
    public var stale: Bool

    public init(plan: String?, windows: [Window], tightest: String?, reportedAt: Date, stale: Bool) {
        self.plan = plan
        self.windows = windows
        self.tightest = tightest
        self.reportedAt = reportedAt
        self.stale = stale
    }

    /// `nil` when nothing was reported or every window reported has reset: the caller then says "unknown".
    public init?(_ limits: RateLimits?, plan: String?, now: Date) {
        guard let limits, let tightest = limits.tightest(now: now) else { return nil }
        let current = limits.current(now: now).sorted { $0.usedPercentage > $1.usedPercentage }
        self.init(plan: plan, windows: current.map { window in
            Window(id: window.id, label: window.label, usedPercentage: window.usedPercentage, resetsAt: window.resetsAt,
                   resetsIn: window.resetsAt.map { max(0, Int($0.timeIntervalSince(now).rounded())) },
                   level: window.level.rawValue)
        }, tightest: tightest.id, reportedAt: limits.reportedAt, stale: limits.isStale(now: now))
    }
}

/// How the limits read, in the app and on the command line: `31%`, `resets in 35 min`, `5h 31% · resets in 35 min`.
public enum RateLimitText {
    /// `31%`, `99%`, `100%`, `>100%`: whole percent, never a figure finer than Claude Code gives.
    public static func percent(_ value: Double) -> String {
        if value > 100 { return ">100%" }
        return "\(Int(value.rounded()))%"
    }

    /// `35 min`, `2 h 05`, `3 d 4 h`, `now`: the time until `date`, coarse on purpose.
    public static func remaining(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 30 else { return "now" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%d h %02d", hours, minutes % 60) }
        let days = hours / 24
        return hours % 24 == 0 ? "\(days) d" : "\(days) d \(hours % 24) h"
    }

    /// `resets in 35 min`, `resets at reset`; `""` when the window names no reset.
    public static func reset(_ window: RateLimits.Window, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return "" }
        return "resets in " + remaining(until: resetsAt, now: now)
    }

    /// One toolbar-sized line about the tightest window: `31% · 35 min`.
    public static func headline(_ window: RateLimits.Window, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return percent(window.usedPercentage) }
        return percent(window.usedPercentage) + " · " + remaining(until: resetsAt, now: now)
    }

    /// `5h 31% (resets in 35 min) · 7d 36% (resets in 3 d 4 h)`, for `scope list` and `scope ping`.
    public static func line(_ summary: RateLimitsSummary, now: Date) -> String {
        let parts = summary.windows.map { window -> String in
            var text = RateLimitWindows.shortLabel(for: window.id) + " " + percent(window.usedPercentage)
            if let resetsAt = window.resetsAt { text += " (resets in \(remaining(until: resetsAt, now: now)))" }
            return text
        }
        var line = parts.joined(separator: " · ")
        if let plan = summary.plan { line = plan + " — " + line }
        if summary.stale { line += " · reported \(remaining(until: now, now: summary.reportedAt)) ago" }
        return line
    }

    /// `12 min ago`, `just now`.
    public static func age(_ reportedAt: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(reportedAt)
        return seconds < 60 ? "just now" : remaining(until: now, now: reportedAt) + " ago"
    }

    /// What is said where no limit is known.
    public static let unknown = "unknown — Claude Code reports them for Pro and Max accounts once a thread has answered"
}
