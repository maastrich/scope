import AppKit
import Foundation
import ScopeControl
import ScopeCore

/// `scope://task/new?scope=…&prompt=…`: a link that asks for a task. `scope://thread?session=…&pid=…`: a link that
/// selects a thread (`ThreadLink`).
extension AppModel {
    /// Shows what the link asks for, then — once the user agreed — runs it through the control service's
    /// `task.new`, the path `scope task new` takes: the same request resolution, proposal and creation.
    ///
    /// A link can come from any web page, so it never gets the free pass of the user's own terminal without the
    /// user saying so: nothing is created before the confirmation. Selecting a thread creates nothing, so a thread
    /// link needs none.
    func open(url: URL) async {
        if let link = ThreadLink(url: url) {
            await waitForBootstrap()
            open(link)
            return
        }
        guard var params = ScopeURL.taskNew(from: url) else {
            problems.warn("Scope does not know what this link asks for", detail: url.absoluteString)
            return
        }
        await waitForBootstrap()
        if params.scope == nil { params.scope = currentScope?.declaration.slug }
        params.dryRun = false
        NSApp.activate()
        let scopeName = params.scope.flatMap { query in
            scopes.first { $0.declaration.slug == query || $0.name == query }?.name ?? query
        } ?? "the current scope"
        var detail = "A link asks Scope for a task:\n\n“\(params.prompt.prefix(600))”"
        if !params.repos.isEmpty { detail += "\n\nRepositories: \(params.repos.joined(separator: ", "))" }
        if let branch = params.branch { detail += "\nBranch: \(branch)" }
        guard await confirmForce(title: "Create a task in \(scopeName)?", detail: detail, button: "Create Task",
                                 destructive: false) else { return }
        guard let service = env.controls.service else { return }
        let result = await service.perform(.taskNew(params), from: .user,
                                           caller: ControlCaller(client: "scope-url"), progress: { _ in })
        if case .failure(let error) = result {
            problems.error("Could not create the task the link asked for", detail: error.description)
        }
    }

    /// A cold launch from a link: the scopes and threads are not loaded yet. Gives up after 20 s.
    private func waitForBootstrap() async {
        var waited = 0
        while !isBootstrapped, waited < 100 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
    }
}
