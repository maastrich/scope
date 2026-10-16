import Foundation
import ScopeCore

/// Branch naming helpers for tasks. A task's branch is proposed from the repository's own convention
/// (`TaskProposer`), never under the reserved `scope/` prefix.
public enum TaskBranch {
    /// Fallback slug for an empty or unslugifiable task name.
    public static let fallbackSlug = "task"

    /// The prefix no task branch may use: Scope keeps the `scope` namespace for its own refs (`refs/scope/salvage/…`),
    /// and a task branch under it would read as one of them.
    public static let reservedPrefix = "scope/"

    /// `true` for a branch under `reservedPrefix`.
    public static func isReserved(_ branch: String) -> Bool {
        branch.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(reservedPrefix)
    }

    /// What to do instead of asking for a reserved branch.
    public static let reservedAdvice = "omit the branch and Scope names it after the repository's convention, "
        + "or use another prefix such as feat/"

    /// The refusal of a reserved branch, said so that the caller knows what to do next.
    public static func reservedRefusal(_ branch: String) -> String {
        "\"\(branch)\" is not a valid task branch: the \(reservedPrefix) prefix is reserved for Scope; \(reservedAdvice)"
    }

    /// Builds `<prefix>/<slug>` for a task. Unused by task creation since branches are proposed from the
    /// repository's convention (`Preferences.branchPrefix` is deprecated); kept for its slug rules.
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
