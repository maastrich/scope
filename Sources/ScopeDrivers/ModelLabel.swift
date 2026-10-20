import Foundation

/// How a thread's model reads in the inspector: `Fable 5.1`, `Opus 5.5 · Claude Code 2.1.47`.
///
/// The driver's own display name wins when it reported one (Claude Code's status line says `Fable 5.1`); otherwise
/// the id the thread was opened with is made readable — `claude-fable-5-1` → `Fable 5.1`, `opus[1m]` → `Opus [1m]`,
/// `haiku` → `Haiku` — and an id of a shape Scope does not know is shown as it is.
public enum ModelLabel {
    /// The readable name of a model id, `nil` for a blank one.
    public static func name(_ id: String?) -> String? {
        guard let raw = id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // `opus[1m]`: the context-window suffix Claude Code accepts, kept apart from the family.
        var suffix = ""
        var base = raw
        if let bracket = raw.firstIndex(of: "[") {
            suffix = " " + String(raw[bracket...])
            base = String(raw[..<bracket])
        }
        let parts = base.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return raw }
        var words = parts
        if words.first?.lowercased() == "claude" { words.removeFirst() }
        guard let family = words.first else { return raw }
        // `fable-5-1` → `Fable 5.1`; `sonnet-4-5-20250929` keeps only the version numbers; `haiku` alone stays.
        let numbers = words.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
        let version = numbers.joined(separator: ".")
        let rest = words.dropFirst().dropFirst(numbers.count).filter { !($0.allSatisfy(\.isNumber) && $0.count >= 6) }
        var label = family.prefix(1).uppercased() + family.dropFirst()
        if !version.isEmpty { label += " " + version }
        if !rest.isEmpty { label += " " + rest.joined(separator: " ") }
        return label + suffix
    }

    /// The model line of the Context card: the name, then the driver and its version when known, joined by ` · `.
    /// `nil` when nothing names a model.
    public static func line(model id: String?, reportedName: String?, driver: String?, driverVersion: String?) -> String? {
        guard let name = reportedName?.trimmingCharacters(in: .whitespaces).nonEmpty ?? name(id) else { return nil }
        var parts = [name]
        if let driver = driver?.nonEmpty {
            parts.append(driverVersion?.nonEmpty.map { "\(driver) \($0)" } ?? driver)
        }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
