import Foundation

/// Why a Claude Code turn ended on `StopFailure`, read from the hook's `error` code and the words of the error it
/// printed (`last_assistant_message`, `error_details`).
///
/// The code alone does not tell a network failure apart: Claude Code 2.1 maps a dropped or refused connection to
/// `unknown` (`API Error: Unable to connect to API (ECONNREFUSED)`, `Connection dropped (ECONNRESET)`), a timeout to
/// `server_error` (`Request timed out`), and keeps `rate_limit` both for the account's own limit and for a server
/// asking clients to slow down (`Server is temporarily limiting requests (not your usage limit)`). So the words decide,
/// and only for the codes a network failure can carry.
public enum TurnFailure: Sendable, Equatable {
    /// The API could not be reached: the network dropped, a VPN came up or went down, the Mac slept.
    case network(String)
    /// The account's usage limit (5-hour or weekly): over at `resetsAt`, when known.
    case usageLimit(resetsAt: Date?)
    /// A server telling clients to slow down: not the account's limit, over in minutes.
    case throttled
    /// Anything else — authentication, billing, a bad request, an output cap, an overloaded model, a TLS setup
    /// problem: waiting does not fix it, and nothing is relaunched.
    case other(String)

    /// The journal token.
    public var cause: String {
        switch self {
        case .network(let cause): "network-\(cause)"
        case .usageLimit: "usage-limit"
        case .throttled: "throttled"
        case .other(let code): code.isEmpty ? "unknown" : code.replacingOccurrences(of: "_", with: "-")
        }
    }

    /// A usage window as Scope last read it from the status line (`RateLimits.Window`).
    public struct Window: Sendable, Equatable {
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(usedPercentage: Double, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    /// Codes a connection failure can come under. A failure with any other code is what its code says.
    static let networkCodes: Set<String> = ["", "unknown", "server_error"]

    /// The words of Claude Code's connection errors (`cwe()` in 2.1.312) and of a stream cut mid-response (all
    /// `server_error`), lowercased; first match wins.
    static let networkNeedles: [(String, String)] = [
        ("connection lost while your computer was asleep", "asleep"),
        ("your computer went to sleep", "asleep"),
        ("the response stopped arriving", "stalled"),
        ("the response stalled", "stalled"),
        ("stream idle timeout", "stalled"),
        ("part of the response never arrived", "dropped"),
        ("connection lost", "lost"),
        ("connection refused", "refused"),
        ("connection dropped", "dropped"),
        ("connection closed before the response finished", "dropped"),
        ("no response from api", "no-response"),
        ("request timed out", "timeout"),
        ("couldn't connect through your proxy", "proxy"),
        // The errno says more than the generic sentence around it.
        ("enotfound", "dns"), ("eai_again", "dns"), ("getaddrinfo", "dns"),
        ("enetunreach", "unreachable"), ("enetdown", "unreachable"), ("ehostunreach", "unreachable"),
        ("econnreset", "dropped"), ("econnrefused", "refused"), ("etimedout", "timeout"), ("socket hang up", "dropped"),
        ("unable to connect to api", "unreachable"),
        ("connection error", "unreachable"),
        ("fetch failed", "unreachable"),
    ]

    /// Certificate problems read like connection errors but are a setup problem: no amount of waiting fixes them.
    static let notNetwork = ["certificate", "ssl error", "self-signed"]

    static let usageWords = ["hit your limit", "usage limit", "limit reached", "limit will reset", "resets"]
    static let throttleWords = ["not your usage limit", "temporarily limiting", "overloaded"]

    public static func classify(error code: String?, message: String?, details: String? = nil,
                                windows: [Window] = [], now: Date = .now, timeZone: TimeZone = .current) -> TurnFailure {
        let code = (code ?? "").lowercased()
        let text = [message, details].compactMap { $0 }.joined(separator: "\n")
        let lower = text.lowercased()
        if code == "rate_limit" {
            if throttleWords.contains(where: lower.contains) { return .throttled }
            let exhausted = windows.filter { $0.usedPercentage >= 100 }.compactMap(\.resetsAt).filter { $0 > now }
            // Every window that is full must reset before a turn can run: the latest of them.
            if let reset = exhausted.max() { return .usageLimit(resetsAt: reset) }
            if let reset = resetTime(in: text, now: now, timeZone: timeZone) { return .usageLimit(resetsAt: reset) }
            if usageWords.contains(where: lower.contains) { return .usageLimit(resetsAt: nil) }
            // A bare `rate_limit` with no words: the account's limit is the common case, and its relaunch waits longest.
            return .usageLimit(resetsAt: nil)
        }
        guard networkCodes.contains(code), !notNetwork.contains(where: lower.contains) else { return .other(code) }
        for (needle, cause) in networkNeedles where lower.contains(needle) { return .network(cause) }
        return .other(code)
    }

    /// The reset Claude Code prints in its limit message: `resets 3pm (Europe/Paris)`, `resets 3:30pm`,
    /// `resets 2026-08-08 00:00 UTC`, `resets in 2h 15m`. A clock time is its next occurrence after `now`, in the zone
    /// named in parentheses, else `timeZone`.
    public static func resetTime(in text: String, now: Date, timeZone: TimeZone = .current) -> Date? {
        let lower = text.lowercased()
        guard let range = lower.range(of: "reset") else { return nil }
        let tail = String(lower[range.upperBound...].prefix(80))
        if let relative = relativeDuration(in: tail) { return now.addingTimeInterval(relative) }
        if let match = tail.firstMatch(of: /(\d{4})-(\d{2})-(\d{2})[ t](\d{1,2}):(\d{2})/) {
            var parts = DateComponents()
            parts.year = Int(match.1)
            parts.month = Int(match.2)
            parts.day = Int(match.3)
            parts.hour = Int(match.4)
            parts.minute = Int(match.5)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tail.contains("utc") ? TimeZone(identifier: "UTC")! : zone(in: text) ?? timeZone
            return calendar.date(from: parts)
        }
        guard let match = tail.firstMatch(of: /(\d{1,2})(?::(\d{2}))?\s*(am|pm)/) else { return nil }
        var hour = Int(match.1) ?? 0
        let minute = match.2.flatMap { Int($0) } ?? 0
        guard (1...12).contains(hour), (0...59).contains(minute) else { return nil }
        if match.3 == "pm", hour != 12 { hour += 12 }
        if match.3 == "am", hour == 12 { hour = 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone(in: text) ?? timeZone
        return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                 matchingPolicy: .nextTime)
    }

    /// `(Europe/Paris)` in the original text, whose case the identifier needs.
    private static func zone(in text: String) -> TimeZone? {
        guard let match = text.firstMatch(of: /\(([A-Za-z_]+\/[A-Za-z_\/]+|UTC)\)/) else { return nil }
        return TimeZone(identifier: String(match.1))
    }

    private static func relativeDuration(in tail: String) -> TimeInterval? {
        guard tail.trimmingCharacters(in: .whitespaces).hasPrefix("in ") || tail.contains(" in ") else { return nil }
        var total: TimeInterval = 0
        var found = false
        for match in tail.matches(of: /(\d+)\s*(d|h|m|min|hr|hours?|minutes?|days?)\b/) {
            guard let value = Double(match.1) else { continue }
            found = true
            switch match.2.first {
            case "d": total += value * 86_400
            case "h": total += value * 3_600
            default: total += value * 60
            }
        }
        return found ? total : nil
    }
}

/// When a failed turn is relaunched: the connection's and the usage limit's timing, from plain values.
public enum RelaunchTiming {
    /// The network must have been up this long before a relaunch: a VPN coming up flaps the path for a few seconds.
    public static let networkSettle: TimeInterval = 5
    /// After a usage reset, a margin: the server's clock and Claude Code's view of the window lag a little.
    public static let resetMargin: TimeInterval = 90

    /// The path as `NWPathMonitor` last reported it.
    public struct Network: Sendable, Equatable {
        /// `.satisfied`.
        public var online: Bool
        /// When the path last changed: up, down, another interface, a VPN.
        public var changedAt: Date?

        public init(online: Bool, changedAt: Date? = nil) {
            self.online = online
            self.changedAt = changedAt
        }
    }

    /// When a turn that failed at `failedAt` on the network may be relaunched, `nil` while offline. Once the path
    /// changed after the failure and has been up for `networkSettle`, right then. If it never moved — a blip too
    /// short for the monitor, a server-side drop — on a backoff: 30 s, then 2, 5 and 10 minutes.
    public static func networkRelaunch(failedAt: Date, attempt: Int, network: Network) -> Date? {
        guard network.online else { return nil }
        if let changed = network.changedAt, changed > failedAt { return changed.addingTimeInterval(networkSettle) }
        return failedAt.addingTimeInterval(backoff(attempt, steps: [30, 120, 300, 600]))
    }

    /// When a turn stopped by the usage limit is relaunched: the reset plus a margin, or a backoff without one —
    /// 15, 30, then 60 minutes. A server throttle retries sooner: 1, 2, 5 minutes.
    public static func limitRelaunch(failedAt: Date, resetsAt: Date?, throttled: Bool, attempt: Int) -> Date {
        if let resetsAt, !throttled { return max(resetsAt, failedAt).addingTimeInterval(resetMargin) }
        let steps: [TimeInterval] = throttled ? [60, 120, 300] : [900, 1_800, 3_600]
        return failedAt.addingTimeInterval(backoff(attempt, steps: steps))
    }

    /// A process that exited this long before the Mac reported going to sleep still died "during" it: the sleep
    /// notification comes late, after the network is already down.
    public static let sleepSlack: TimeInterval = 60

    /// Whether a thread found dead on wake is the wake trigger's: its process exited since the Mac went to sleep, with
    /// a turn cut short. One that died idle, or before the sleep, stays as the user left it.
    public static func diedDuringSleep(exitedAt: Date?, turnCutShort: Bool, sleptAt: Date) -> Bool {
        guard turnCutShort, let exitedAt else { return false }
        return exitedAt >= sleptAt.addingTimeInterval(-sleepSlack)
    }

    /// Whether a turn that failed at `failedAt` failed because of the sleep that began at `sleptAt`, if any.
    public static func failedDuringSleep(failedAt: Date, sleptAt: Date?) -> Bool {
        sleptAt.map { failedAt >= $0.addingTimeInterval(-sleepSlack) } ?? false
    }

    static func backoff(_ attempt: Int, steps: [TimeInterval]) -> TimeInterval {
        steps[min(max(attempt, 0), steps.count - 1)]
    }
}
