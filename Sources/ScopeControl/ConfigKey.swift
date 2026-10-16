import Foundation
import ScopeCore

/// The preferences `scope config get|set` reaches.
///
/// `config.json` is read at launch and rewritten by the app, so editing it by hand while Scope runs changes nothing
/// and is lost on the next save. These go through the running app instead, the path the Settings window takes.
/// An allowlist on purpose: each key here is one the user may want to change from a terminal without opening the
/// window, and `AutomationPolicy` keeps agents from changing any of them.
public enum ConfigKey: String, CaseIterable, Sendable {
    case maxAgentTasks = "automation.maxAgentTasks"
    case maxAgentThreads = "automation.maxAgentThreads"

    /// What the key is, as Settings names it.
    public var summary: String {
        switch self {
        case .maxAgentTasks: "Settings ▸ Automation ▸ Open tasks: tasks agents may keep open at once"
        case .maxAgentThreads: "Settings ▸ Automation ▸ Running threads: threads agents may keep running at once"
        }
    }

    /// The key a user typed, compared case-insensitively.
    public static func named(_ name: String) -> Result<ConfigKey, ControlError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = allCases.first(where: { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .success(key)
        }
        return .failure(.badRequest("no setting called “\(trimmed)”",
                                    detail: "`scope config` reaches: " + allCases.map(\.rawValue).joined(separator: ", ")))
    }

    public func value(in settings: AutomationSettings) -> String {
        switch self {
        case .maxAgentTasks: String(settings.maxAgentTasks)
        case .maxAgentThreads: String(settings.maxAgentThreads)
        }
    }

    /// `settings` with `text` applied, or why it cannot be. A value out of range is refused rather than clamped:
    /// the answer would otherwise claim a number that is not the one in force.
    public func applying(_ text: String, to settings: AutomationSettings) -> Result<AutomationSettings, ControlError> {
        let range = AutomationSettings.budgetRange
        guard let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(number) else {
            return .failure(.badRequest("\(rawValue) takes a whole number from \(range.lowerBound) to \(range.upperBound), not “\(text)”"))
        }
        var settings = settings
        switch self {
        case .maxAgentTasks: settings.maxAgentTasks = number
        case .maxAgentThreads: settings.maxAgentThreads = number
        }
        return .success(settings)
    }

    /// `key = value` lines for `scope config get`.
    public static func listing(_ keys: [ConfigKey], in settings: AutomationSettings) -> String {
        keys.map { "\($0.rawValue) = \($0.value(in: settings))" }.joined(separator: "\n")
    }
}

extension ConfigKey {
    /// `config.get`: one key, or all of them.
    public static func get(_ params: ConfigGetParams, in settings: AutomationSettings) -> Result<ControlResultPayload, ControlError> {
        var keys = allCases
        if let name = params.key {
            switch named(name) {
            case .failure(let error): return .failure(error)
            case .success(let key): keys = [key]
            }
        }
        return .success(.action(ActionResult(message: listing(keys, in: settings)), .configGet))
    }

    /// `config.set`: the settings to apply and the answer to give, or why not.
    public static func set(_ params: ConfigSetParams, in settings: AutomationSettings)
        -> Result<(settings: AutomationSettings, answer: ControlResultPayload), ControlError> {
        let key: ConfigKey
        switch named(params.key) {
        case .failure(let error): return .failure(error)
        case .success(let found): key = found
        }
        switch key.applying(params.value, to: settings) {
        case .failure(let error): return .failure(error)
        case .success(let updated):
            let was = key.value(in: settings)
            let now = key.value(in: updated)
            let message = was == now ? "\(key.rawValue) is already \(now)" : "\(key.rawValue) = \(now) (was \(was))"
            return .success((updated, .action(ActionResult(message: message), .configSet)))
        }
    }
}
