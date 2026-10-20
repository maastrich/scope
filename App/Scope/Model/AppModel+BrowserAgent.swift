import Foundation
import ScopeControl
import ScopeCore
import ScopeTasks
import WebKit

/// What the task's agents do with its browser (`scope browser …`, `scope_browser_*`): one tab per task on a data
/// store of the task's own, opened behind the user — the pane shows it, marked, when they look.
extension AppModel {
    /// The task's agent tab, created on first use. Not shown: the user keeps what they were looking at.
    func agentBrowser(of task: TaskState) -> BrowserSession {
        if let existing = browser.agentSession(of: task.id) { return existing }
        let session = BrowserSession(taskID: task.id, storeID: BrowserStoreID.agent(home: env.home, task: task.id.rawValue),
                                     url: nil, kind: .agent)
        // A page of the agent's that opens a window stays in the agent's tab: its store, its story.
        session.onOpenWindow = { session, url in session.load(url) }
        browser.add(session)
        return session
    }

    /// Where `open` goes without a URL: a port of the block something listens on, else another port the task's
    /// processes serve, else what `.claude/launch.json` declares, else `SCOPE_PORT`.
    func firstServer(of task: TaskState) -> URL? {
        if let port = task.listeningPorts.first { return PortBlock.url(for: port) }
        if let port = task.otherPorts.first { return PortBlock.url(for: port) }
        if let launch = task.launchServers.first?.address { return launch }
        return task.record.portBlock.map { PortBlock.url(for: $0.base) }
    }

    func performBrowser(_ params: BrowserParams, in task: TaskState, by driver: String) async -> Result<BrowserResult, ControlError> {
        let session = agentBrowser(of: task)
        session.noteAgent(thread: driver, action: params.action.rawValue)
        Usage.register("browser.agent.\(params.action.rawValue)", label: "Agent browser: \(params.action.rawValue)")
        func result(_ message: String, loading: Bool = false) -> BrowserResult {
            BrowserResult(task: task.id.rawValue, slug: task.record.slug, action: params.action, url: session.url?.absoluteString,
                          title: session.title, loading: loading, message: message)
        }
        switch params.action {
        case .open:
            let fallback = firstServer(of: task)
            let target: URL?
            if params.url == nil, params.port == nil {
                target = fallback
            } else {
                target = BrowserText.target(url: params.url, port: params.port, block: task.record.portBlock,
                                            current: session.url, fallback: fallback)
            }
            guard let target else {
                return .failure(.badRequest("no page to open",
                                            detail: "Give a url (http://localhost:5173, :41001, /checkout) or a port; the task has no server Scope knows of."))
            }
            let loaded = await session.loadAndWait(target)
            if let failure = session.failure {
                var answer = result("could not open \(target.absoluteString): \(failure.message)")
                answer.url = target.absoluteString
                if BrowserRoute.isLocal(target) {
                    answer.message += "\nNothing may be listening there yet: start the dev server on $SCOPE_PORT"
                        + (task.record.portBlock.map { " (\($0.base))" } ?? "") + " and open again."
                }
                return .success(answer)
            }
            let title = session.title.isEmpty ? "" : " (\(session.title))"
            return .success(result(loaded ? "opened \(session.url?.absoluteString ?? target.absoluteString)\(title)"
                                          : "still loading \(target.absoluteString) after 30 s", loading: !loaded))
        case .read, .screenshot, .console:
            guard session.url != nil, session.hasView else {
                return .failure(.badRequest("the task's browser has no page yet", detail: "Open one first: scope_browser_open (or `scope browser open`)."))
            }
            if session.isLoading { _ = await session.waitUntilLoaded(timeout: .seconds(10)) }
            switch params.action {
            case .read:
                do {
                    let page = try await session.readPage()
                    var answer = result("read \(page.url)")
                    answer.page = page.render()
                    return .success(answer)
                } catch {
                    return .failure(.failed("could not read the page", detail: String(describing: error)))
                }
            case .screenshot:
                do {
                    let shot = try await session.snapshotJPEG()
                    let folder = ScopeHome.browserShotsURL(home: env.home, task: task.id.rawValue)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
                        .timeSeparator(.omitted).dateTimeSeparator(.standard)).replacingOccurrences(of: ":", with: "")
                    let file = folder.appending(path: "\(stamp)-\(UUID().uuidString.prefix(4).lowercased()).jpg")
                    try shot.data.write(to: file)
                    var answer = result("screenshot of \(session.url?.absoluteString ?? "the page")")
                    answer.screenshot = file.path
                    answer.width = shot.width
                    answer.height = shot.height
                    return .success(answer)
                } catch {
                    return .failure(.failed("could not take the screenshot", detail: String(describing: error)))
                }
            case .console:
                let lines = session.consoleForAgent(all: params.all ?? false)
                var answer = result("\(lines.count) console \(lines.count == 1 ? "line" : "lines")" + ((params.all ?? false) ? "" : " since the last look"))
                answer.console = lines
                return .success(answer)
            case .open:
                return .failure(.failed("unreachable"))
            }
        }
    }

    /// Archive, close: the agents' store of the task goes with it — after its view, since WebKit refuses to remove a
    /// store a view still uses — and so do its screenshots.
    func removeAgentBrowserData(of taskID: TaskID) {
        let storeID = BrowserStoreID.agent(home: env.home, task: taskID.rawValue)
        try? FileManager.default.removeItem(at: ScopeHome.browserShotsURL(home: env.home, task: taskID.rawValue))
        Task { @MainActor in
            // The WebContent process lets go of the store a moment after the view is gone.
            for attempt in 0..<5 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
                let known = await WKWebsiteDataStore.allDataStoreIdentifiers
                guard known.contains(storeID) else { return }
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: storeID)
                    return
                } catch {
                    Log.app.debug("agent browser store of \(taskID.rawValue, privacy: .public) not removed yet: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
