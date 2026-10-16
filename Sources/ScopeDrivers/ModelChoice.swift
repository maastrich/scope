import Foundation

/// Which model a new thread runs on, out of everything that has a say (spec §5).
///
/// In order: the model the request names; the one the calling agent runs on, when it opens a thread of its own
/// driver; the scope's default; the driver's default from Settings; and none, which leaves the driver to its own
/// default. Blank strings count as nothing said.
public enum ModelChoice {
    public static func resolve(requested: String? = nil, inherited: String? = nil,
                               scopeDefault: String? = nil, driverDefault: String? = nil) -> String? {
        for candidate in [requested, inherited, scopeDefault, driverDefault] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }

    /// What an agent passes on: its own model, only toward a thread of the same driver — a Claude model means
    /// nothing to Codex.
    public static func inherited(callerModel: String?, callerDriver: String?, driver: String) -> String? {
        guard let callerDriver, callerDriver == driver else { return nil }
        return callerModel
    }
}
