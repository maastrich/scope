import Foundation
import ScopeCore

/// Branch naming for tasks (M2): `<prefix>/<slug>`, `scope/auth-refresh` by default.
public enum TaskBranch {
    /// Fallback slug for an empty or unslugifiable task name.
    public static let fallbackSlug = "task"

    /// Builds the branch name for a task.
    ///
    /// - Parameters:
    ///   - prefix: `Preferences.branchPrefix`, e.g. `"scope"` or `"mathis/wip"`. Each `/`-separated
    ///     component is slugified; an empty prefix yields the bare slug.
    ///   - taskName: the task name as typed by the user; slugified (`"Auth Refresh (v2)!"` → `auth-refresh-v2`).
    public static func name(prefix: String, taskName: String) -> String {
        var components = prefix
            .split(separator: "/")
            .map { slugify(String($0), fallback: "") }
            .filter { !$0.isEmpty }
        components.append(slug(for: taskName))
        return components.joined(separator: "/")
    }

    /// The slug part alone (also the sandbox folder name).
    public static func slug(for taskName: String) -> String {
        slugify(taskName, fallback: fallbackSlug)
    }

    /// `name` when no branch in `taken` has it, else `name-2`, `name-3`… — the way out when the branch a task
    /// wanted is checked out in another working tree.
    public static func alternative(to name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name)-\(suffix)") { suffix += 1 }
        return "\(name)-\(suffix)"
    }
}
