import Foundation

/// A trigger that acts on a thread when its surroundings change (spec §4.10, "triggers that act"): it types a message
/// into the thread, restarts its session, or interrupts its turn — unlike the assistant's jobs, which only label.
/// The raw value is what the journal and `config.json` keep.
public enum ActingTrigger: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A turn failed on a connection error: relaunched once the network is back.
    case connectionLost = "connection-lost"
    /// The Mac woke up: threads whose process died or whose turn failed meanwhile are relaunched, network first.
    case wake
    /// A turn failed on the account's usage limit: relaunched when the window resets.
    case usageLimit = "usage-limit"
    /// The task's pull request conflicts with its base, or a rebase Scope tried stopped on conflicts.
    case conflicts
    /// The task's pull request failed its checks while the thread sat idle.
    case ciFailed = "ci-failed"
    /// Someone reviewed or commented on the task's pull request.
    case review
    /// The base branch got commits touching files the task changed: a rebase before it becomes a conflict.
    case baseMoved = "base-moved"
    /// The assistant reads the running turn as going in circles: interrupted, and asked to change approach.
    case stuck

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .connectionLost: "Connection lost"
        case .wake: "Mac woke up"
        case .usageLimit: "Usage limit reached"
        case .conflicts: "Pull request conflicts"
        case .ciFailed: "Checks failed"
        case .review: "Review received"
        case .baseMoved: "Base branch moved"
        case .stuck: "Thread seems stuck"
        }
    }

    /// What it does, for Settings.
    public var summary: String {
        switch self {
        case .connectionLost: "A turn that failed on a network error is resumed as soon as the connection is back."
        case .wake: "After sleep, threads that died or failed meanwhile are resumed once the network is back."
        case .usageLimit: "A turn stopped by the 5-hour or weekly limit is resumed when the limit resets."
        case .conflicts: "The task's thread is asked to bring in the base branch and resolve the conflicts."
        case .ciFailed: "An idle task's thread gets the failed jobs and is asked to rerun a flaky one or fix it."
        case .review: "The task's thread gets new review comments, Copilot's included, to address."
        case .baseMoved: "An idle task with an open pull request is asked to update when the base touches its files."
        case .stuck: "A turn the assistant reads as going in circles is interrupted and asked to change approach."
        }
    }
}

/// One trigger's preference: whether it runs, and how many times per hour it may act on one thread.
public struct ActingTriggerPreference: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var hourlyCap: Int

    public init(enabled: Bool, hourlyCap: Int) {
        self.enabled = enabled
        self.hourlyCap = min(max(hourlyCap, Self.capRange.lowerBound), Self.capRange.upperBound)
    }

    public static let capRange = 1...10
}

/// Every trigger's preference. Stored as `{"connection-lost": {"enabled": true, "hourlyCap": 3}, …}`; a trigger
/// missing from the document — every one of them in a config written before triggers existed — has its default.
public struct ActingTriggerPreferences: Codable, Sendable, Equatable {
    private var overrides: [ActingTrigger: ActingTriggerPreference]

    public init(_ overrides: [ActingTrigger: ActingTriggerPreference] = [:]) {
        self.overrides = overrides
    }

    /// Safe defaults: everything on, and few enough relaunches that a trigger gone wrong costs a handful of turns,
    /// not an afternoon. Network and wake retry a bit more because a flapping Wi-Fi fails a turn more than once.
    public static func defaultPreference(_ trigger: ActingTrigger) -> ActingTriggerPreference {
        switch trigger {
        case .connectionLost: .init(enabled: true, hourlyCap: 3)
        case .wake: .init(enabled: true, hourlyCap: 2)
        case .usageLimit: .init(enabled: true, hourlyCap: 2)
        case .conflicts: .init(enabled: true, hourlyCap: 2)
        case .ciFailed: .init(enabled: true, hourlyCap: 2)
        case .review: .init(enabled: true, hourlyCap: 3)
        case .baseMoved: .init(enabled: true, hourlyCap: 1)
        case .stuck: .init(enabled: true, hourlyCap: 2)
        }
    }

    public subscript(trigger: ActingTrigger) -> ActingTriggerPreference {
        get { overrides[trigger] ?? Self.defaultPreference(trigger) }
        set { overrides[trigger] = newValue == Self.defaultPreference(trigger) ? nil : newValue }
    }

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode([String: ActingTriggerPreference].self)) ?? [:]
        var overrides: [ActingTrigger: ActingTriggerPreference] = [:]
        for (key, value) in raw {
            guard let trigger = ActingTrigger(rawValue: key) else { continue }
            overrides[trigger] = value
        }
        self.overrides = overrides
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }))
    }
}

extension ActingTriggerPreference {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        let cap = (try? container.decodeIfPresent(Int.self, forKey: .hourlyCap)) ?? 2
        self.init(enabled: enabled, hourlyCap: cap)
    }
}
