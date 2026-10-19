import Foundation
import ScopeCore

/// What the assistant did today: calls per tier and the verdicts the user overruled. Kept in `<home>/assist.json`
/// so the daily cap holds across a relaunch; the day is the local calendar's.
public struct AssistLedger: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// `yyyy-MM-dd` in the local calendar.
    public var day: String
    public var onDeviceCalls: Int
    public var haikuCalls: Int
    /// "Not stuck" and "Not blocking" presses.
    public var falsePositives: Int

    public init(day: String, onDeviceCalls: Int = 0, haikuCalls: Int = 0, falsePositives: Int = 0) {
        version = Self.currentVersion
        self.day = day
        self.onDeviceCalls = onDeviceCalls
        self.haikuCalls = haikuCalls
        self.falsePositives = falsePositives
    }

    public static func dayKey(_ date: Date = .now, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The ledger for `date`: this one when it is the same day, a fresh one otherwise.
    public func forDay(_ date: Date, calendar: Calendar = .current) -> AssistLedger {
        let key = Self.dayKey(date, calendar: calendar)
        return key == day ? self : AssistLedger(day: key)
    }

    public func calls(for tier: AssistTier) -> Int {
        switch tier {
        case .onDevice: onDeviceCalls
        case .haiku: haikuCalls
        }
    }

    public mutating func count(_ tier: AssistTier) {
        switch tier {
        case .onDevice: onDeviceCalls += 1
        case .haiku: haikuCalls += 1
        }
    }
}

/// Owner of `<home>/assist.json`.
public actor AssistLedgerStore {
    public nonisolated let url: URL
    private var ledger: AssistLedger?

    public init(home: URL) {
        url = home.appending(path: "assist.json", directoryHint: .notDirectory)
    }

    /// Today's ledger, read once from disk; an unreadable or older file counts as an empty day.
    public func today(now: Date = .now) -> AssistLedger {
        if ledger == nil {
            let saved = try? JSONStore.load(AssistLedger.self, from: url)
            ledger = saved.flatMap { $0.version == AssistLedger.currentVersion ? $0 : nil } ?? AssistLedger(day: AssistLedger.dayKey(now))
        }
        let current = ledger!.forDay(now)
        ledger = current
        return current
    }

    @discardableResult
    public func count(_ tier: AssistTier, now: Date = .now) -> AssistLedger {
        var current = today(now: now)
        current.count(tier)
        persist(current)
        return current
    }

    @discardableResult
    public func countFalsePositive(now: Date = .now) -> AssistLedger {
        var current = today(now: now)
        current.falsePositives += 1
        persist(current)
        return current
    }

    private func persist(_ ledger: AssistLedger) {
        self.ledger = ledger
        do {
            try JSONStore.save(ledger, to: url)
        } catch {
            Log.app.error("assist ledger write failed: \(String(describing: error))")
        }
    }
}
