import Foundation

/// `scope://task/new?scope=acme&prompt=…` — a link that asks for a task, read into the same `task.new` call the
/// command line builds.
///
/// Recognised query items: `prompt` (required), `scope`, `repo` (repeatable), `branch`, `title`, `slug`,
/// `driver`, and `setup=0` to skip the setup commands. Anything else is ignored. The scheme is the app's
/// (`scope`, `scope-debug` for a Debug build) and is not checked here.
public enum ScopeURL {
    public static func taskNew(from url: URL) -> TaskNewParams? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "task", components.path == "/new" || components.path == "new" else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        guard let prompt = value("prompt")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let setup = value("setup")?.lowercased()
        return TaskNewParams(
            prompt: prompt, scope: value("scope"),
            repos: items.filter { $0.name == "repo" }.compactMap(\.value).filter { !$0.isEmpty },
            branch: value("branch"), title: value("title"), slug: value("slug"), driver: value("driver"),
            runSetup: !(setup == "0" || setup == "false" || setup == "no")
        )
    }
}
