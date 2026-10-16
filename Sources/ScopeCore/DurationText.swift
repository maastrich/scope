import Foundation

/// A span of time in the fewest words that still tell minutes from days: `45 s`, `12 min`, `3 h 20`, `2 d 4 h`.
/// Shared by the task timeline and `scope summary`, so the same stretch reads the same in both.
public enum DurationText {
    public static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 { return restMinutes == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", restMinutes))" }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? "\(days) d" : "\(days) d \(restHours) h"
    }
}
