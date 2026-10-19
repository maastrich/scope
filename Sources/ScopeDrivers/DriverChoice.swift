import Foundation

/// Which driver a new thread runs when the caller did not name one.
///
/// One rule for every creation path — the user's ⌘T, `scope thread new`, `scope_task_new`, a schedule, an attempt:
/// the driver asked for, else the one chosen in Settings ▸ Default driver, else the first agent profile installed
/// (the shell is a choice, never the fallback). The driver last opened in the scope only ever stands in for an
/// *empty* preference, and only for the user's own ⌘T: it is a convenience of the UI, not a setting, so it is
/// never passed on for a thread an agent or a schedule asks for, and never overrides a preference the user set.
public enum DriverChoice {
    /// `requested` when installed, else `preference` when set and installed, else `lastOpened` when installed,
    /// else the first profile that is not the shell, else the first profile.
    public static func resolve(requested: String? = nil, preference: String, lastOpened: String? = nil,
                               profiles: [DriverProfile]) -> DriverProfile? {
        for id in [requested, preference, lastOpened] {
            guard let id, !id.isEmpty, let profile = profiles.first(where: { $0.id == id }) else { continue }
            return profile
        }
        return profiles.first { $0.id != "shell" } ?? profiles.first
    }
}
