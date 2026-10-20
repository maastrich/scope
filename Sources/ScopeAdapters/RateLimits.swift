import Foundation
import ScopeCore

/// A subscription's limits as Claude Code reports them: for each window, the share consumed and when it resets.
///
/// Source: the JSON Claude Code hands its status line on every assistant message carries `rate_limits`, with one
/// object per window (`five_hour`, `seven_day`, and whatever the plan adds — a per-model week, a gateway's
/// `spend_limit`), each holding `used_percentage` (0–100, above once exceeded) and `resets_at` (epoch seconds). It is
/// present for claude.ai Pro and Max subscribers only, after the session's first answer, and Claude Code drops a
/// window once its `resets_at` has passed (code.claude.com/docs/en/statusline). Scope's per-thread settings file
/// installs a status line that forwards that object (`scope-hook statusline`) before running the user's own, so
/// these figures are Claude Code's, never Scope's estimate: when none was reported, the meter says so.
public struct RateLimits: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable, Identifiable {
        /// The key under `rate_limits`: `five_hour`, `seven_day`, `seven_day_opus`, `spend_limit`, …
        public var id: String
        /// 0–100, above 100 once the limit is exceeded.
        public var usedPercentage: Double
        public var resetsAt: Date?
        /// `spend_limit` only: the gateway's estimate of what was spent and the cap, in US dollars, and the period
        /// (`daily`, `weekly`, `monthly`). Each may be absent.
        public var usedUSD: Double?
        public var limitUSD: Double?
        public var period: String?

        public init(id: String, usedPercentage: Double, resetsAt: Date? = nil, usedUSD: Double? = nil,
                    limitUSD: Double? = nil, period: String? = nil) {
            self.id = id
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
            self.usedUSD = usedUSD
            self.limitUSD = limitUSD
            self.period = period
        }

        /// `true` once `resetsAt` has passed: the window has reset and the figure says nothing about the new one.
        public func hasReset(now: Date) -> Bool {
            guard let resetsAt else { return false }
            return resetsAt <= now
        }

        /// How the window reads: `5-hour session`, `Weekly`, `Weekly · Opus`, `Spend limit`.
        public var label: String { RateLimitWindows.label(for: id) }
        /// Its short form for a toolbar or a table: `5h`, `7d`, `7d Opus`, `spend`.
        public var shortLabel: String { RateLimitWindows.shortLabel(for: id) }
        public var level: RateLimitLevel { RateLimitLevel(percentage: usedPercentage) }
    }

    /// In display order: the known windows first (`RateLimitWindows.order`), then the rest alphabetically.
    public var windows: [Window]
    /// When Claude Code wrote the status line these came from.
    public var reportedAt: Date
    /// The thread whose session reported them; every thread of one account sees the same limits.
    public var thread: String?

    public init(windows: [Window], reportedAt: Date, thread: String? = nil) {
        self.windows = windows
        self.reportedAt = reportedAt
        self.thread = thread
    }

    // MARK: Parsing

    /// The `rate_limits` object of a status-line payload, serialized compactly, for the hook's payload. `nil` when
    /// the payload has none (API key, first message not answered yet).
    public static func extract(statusline data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any], !limits.isEmpty,
              let encoded = try? JSONSerialization.data(withJSONObject: limits, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Parses the `rate_limits` object (as `extract` serialized it, or straight from a status-line payload). Windows
    /// without a readable `used_percentage` are skipped; `nil` when none is left.
    public static func parse(_ json: String, reportedAt: Date, thread: String? = nil) -> RateLimits? {
        parse(Data(json.utf8), reportedAt: reportedAt, thread: thread)
    }

    public static func parse(_ data: Data, reportedAt: Date, thread: String? = nil) -> RateLimits? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let nested = object["rate_limits"] as? [String: Any] { object = nested }
        var windows: [Window] = []
        for (key, value) in object {
            guard let fields = value as? [String: Any],
                  let used = (fields["used_percentage"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
            let resetsAt = (fields["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(Window(id: key, usedPercentage: max(0, used), resetsAt: resetsAt,
                                  usedUSD: (fields["used_usd"] as? NSNumber)?.doubleValue,
                                  limitUSD: (fields["limit_usd"] as? NSNumber)?.doubleValue,
                                  period: fields["period"] as? String))
        }
        guard !windows.isEmpty else { return nil }
        return RateLimits(windows: RateLimitWindows.sorted(windows), reportedAt: reportedAt, thread: thread)
    }

    // MARK: Reading

    /// The windows still standing at `now`: one past its reset is gone, as Claude Code itself drops it.
    public func current(now: Date) -> [Window] {
        windows.filter { !$0.hasReset(now: now) }
    }

    /// The window nearest its ceiling: the highest percentage, the earliest reset on a tie. `nil` once every window
    /// has reset — the figures are then about periods that are over.
    public func tightest(now: Date) -> Window? {
        current(now: now).max { lhs, rhs in
            if lhs.usedPercentage != rhs.usedPercentage { return lhs.usedPercentage < rhs.usedPercentage }
            return (lhs.resetsAt ?? .distantFuture) > (rhs.resetsAt ?? .distantFuture)
        }
    }

    /// Seconds since Claude Code reported these.
    public func age(now: Date) -> TimeInterval { max(0, now.timeIntervalSince(reportedAt)) }

    /// How long a report stays worth showing without a newer one. A percentage never rises between reports — only
    /// a thread's own calls raise it, and each one re-runs the status line — but usage from claude.ai or another
    /// machine would not show, so an old report is flagged rather than hidden.
    public static let staleAfter: TimeInterval = 30 * 60

    public func isStale(now: Date) -> Bool { age(now: now) > Self.staleAfter }
}

/// How the windows Claude Code names read, and in which order.
public enum RateLimitWindows {
    /// Known keys, in display order. Anything else goes after, alphabetically, under a label made from its key.
    public static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "spend_limit"]

    public static func label(for id: String) -> String {
        switch id {
        case "five_hour": "5-hour session"
        case "seven_day": "Weekly"
        case "spend_limit": "Spend limit"
        default:
            if id.hasPrefix("seven_day_") { "Weekly · " + id.dropFirst("seven_day_".count).capitalized }
            else { id.replacingOccurrences(of: "_", with: " ").capitalized }
        }
    }

    public static func shortLabel(for id: String) -> String {
        switch id {
        case "five_hour": "5h"
        case "seven_day": "7d"
        case "spend_limit": "spend"
        default:
            if id.hasPrefix("seven_day_") { "7d " + id.dropFirst("seven_day_".count).capitalized }
            else { id.replacingOccurrences(of: "_", with: " ") }
        }
    }

    public static func sorted(_ windows: [RateLimits.Window]) -> [RateLimits.Window] {
        windows.sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.id) ?? order.count
            let r = order.firstIndex(of: rhs.id) ?? order.count
            return l != r ? l < r : lhs.id < rhs.id
        }
    }
}

/// How close to the ceiling a percentage is, for the meter's colour and an agent's pace.
public enum RateLimitLevel: String, Codable, Sendable, Equatable, CaseIterable {
    /// Under half.
    case calm
    /// Half to four fifths.
    case watch
    /// Four fifths to the ceiling.
    case tight
    /// At or past 100 %: Claude Code is being refused until the reset.
    case exhausted

    public init(percentage: Double) {
        self = switch percentage {
        case ..<50: .calm
        case ..<80: .watch
        case ..<100: .tight
        default: .exhausted
        }
    }
}

/// Keeps the last report in `<home>/limits.json`, so the meter shows at launch what the previous run last saw —
/// marked by its age — rather than nothing until a thread answers. Pure apart from the file.
public actor RateLimitsStore {
    public nonisolated let url: URL

    public init(home: URL) {
        url = ScopeHome.limitsURL(home: home)
    }

    public func load() -> RateLimits? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONStore.makeDecoder(fractionalSeconds: true).decode(RateLimits.self, from: data)
    }

    public func save(_ limits: RateLimits) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONStore.makeEncoder(fractionalSeconds: true).encode(limits).write(to: url, options: .atomic)
        } catch {
            Log.threads.error("limits write failed: \(String(describing: error))")
        }
    }
}
