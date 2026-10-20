import CryptoKit
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
        // Compare captures in views of its own: no agent tab to open for it.
        if params.action == .compare {
            Usage.register("browser.agent.compare", label: "Agent browser: compare")
            return await compareBrowser(params, in: task)
        }
        let session = agentBrowser(of: task)
        guard !session.isStopped else {
            return .failure(.denied("the user stopped the browser of \(task.record.slug)",
                                    detail: "They resume it from the task's Browser pane. Do not work around it."))
        }
        Usage.register("browser.agent.\(params.action.rawValue)", label: "Agent browser: \(params.action.rawValue)")
        await applyAgentRules(to: session, of: task)
        let detail = params.url ?? params.port.map { ":\($0)" } ?? params.ref.map { ref in params.text.map { "\(ref) “\($0.prefix(40))”" } ?? ref }
            ?? params.selector ?? params.text ?? ""
        return await session.agentCall(thread: driver, action: params.action.rawValue, detail: detail) {
            let result = await browserAction(params, session: session, task: task)
            let outcome: String = switch result {
            case .success(let answer): answer.message.split(separator: "\n").first.map(String.init) ?? "ok"
            case .failure(let error): "refused: " + error.message
            }
            return (result, session.isStopped ? "stopped by you" : outcome)
        }
    }

    private func browserAction(_ params: BrowserParams, session: BrowserSession, task: TaskState) async -> Result<BrowserResult, ControlError> {
        func result(_ message: String, loading: Bool = false) -> BrowserResult {
            BrowserResult(task: task.id.rawValue, slug: task.record.slug, action: params.action, url: session.url?.absoluteString,
                          title: session.title, loading: loading, message: message)
        }
        func stopped() -> Result<BrowserResult, ControlError> {
            .failure(.denied("the user stopped the browser of \(task.record.slug)", detail: "They resume it from the task's Browser pane."))
        }
        /// After something that may navigate: wait for it, and say where the tab stands.
        func settle(_ what: String) async -> Result<BrowserResult, ControlError> {
            try? await Task.sleep(for: .milliseconds(150))
            let loaded = await session.waitUntilLoaded(timeout: .seconds(15))
            if session.isStopped { return stopped() }
            if let failure = session.failure { return .success(result("\(what); the page then failed: \(failure.message)")) }
            return .success(result(what + (loaded ? "" : "; the page is still loading"), loading: !loaded))
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
            if let refusal = BrowserSitePolicy.refusal(for: target, sites: config.preferences.automationSettings.browserSites,
                                                        block: task.record.portBlock, blocked: blockedHosts(of: task)) {
                return .failure(.denied(refusal, detail: "The user decides where agents browse: Settings ▸ Automation ▸ Browser."))
            }
            let downloadsBefore = session.downloads.count
            let loaded = await session.loadAndWait(target)
            if session.isStopped { return stopped() }
            if session.downloads.count > downloadsBefore, let file = session.downloads.last {
                return .success(result("\(target.absoluteString) is a download: saved to \(file.path)"))
            }
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
        default:
            break
        }
        guard session.url != nil, session.hasView else {
            return .failure(.badRequest("the task's browser has no page yet", detail: "Open one first: scope_browser_open (or `scope browser open`)."))
        }
        if session.isLoading { _ = await session.waitUntilLoaded(timeout: .seconds(10)) }
        switch params.action {
        case .open, .compare:
            return .failure(.failed("unreachable"))
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
        case .network:
            await session.collectResources()
            let entries = session.networkForAgent(all: params.all ?? false)
            var answer = result("\(entries.count) \(entries.count == 1 ? "request" : "requests")" + ((params.all ?? false) ? "" : " since the last look")
                                + " (status for fetch/XHR only)")
            answer.network = entries
            return .success(answer)
        case .click:
            guard let ref = params.ref?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
                return .failure(.badRequest("say which element: a ref from scope_browser_read, e.g. e12"))
            }
            do {
                let answer = try await session.callInWorld(BrowserScripts.click, ["ref": ref])
                guard answer["ok"] as? Bool == true else {
                    return .failure(.notFound(answer["error"] as? String ?? "no element \(ref)"))
                }
                return await settle("clicked \(ref)")
            } catch {
                return .failure(.failed("could not click \(ref)", detail: String(describing: error)))
            }
        case .type:
            guard let ref = params.ref?.trimmingCharacters(in: .whitespaces), !ref.isEmpty, let text = params.text else {
                return .failure(.badRequest("say which field (a ref from scope_browser_read) and what to type"))
            }
            do {
                let answer = try await session.callInWorld(BrowserScripts.type, ["ref": ref, "text": text, "clear": params.clear ?? false,
                                                                                 "submit": params.submit ?? false])
                guard answer["ok"] as? Bool == true else {
                    return .failure(.notFound(answer["error"] as? String ?? "could not type into \(ref)"))
                }
                let value = (answer["value"] as? String).map { " — it now reads “\($0.prefix(200))”" } ?? ""
                if answer["submitted"] as? Bool == true { return await settle("typed into \(ref) and submitted\(value)") }
                return .success(result("typed into \(ref)\(value)"))
            } catch {
                return .failure(.failed("could not type into \(ref)", detail: String(describing: error)))
            }
        case .wait:
            let found = await session.waitFor(selector: params.selector, text: params.text, timeout: .seconds(params.waitSeconds))
            if session.isStopped { return stopped() }
            let what = params.selector.map { "“\($0)”" } ?? params.text.map { "the text “\($0.prefix(60))”" } ?? "the page to go quiet"
            return .success(result(found ? "ok: \(what)" : "timeout after \(params.waitSeconds) s waiting for \(what)"))
        }
    }

    /// The hosts blocked for `task`'s agents: Settings' and the pane's.
    func blockedHosts(of task: TaskState) -> [String] {
        BrowserSitePolicy.normalized(config.preferences.automationSettings.browserBlocked + task.browserBlocked)
    }

    /// The rules WebKit enforces on the agent's tab, compiled once per distinct list.
    func applyAgentRules(to session: BrowserSession, of task: TaskState) async {
        session.downloadsFolder = env.home.appending(path: "browser/downloads/\(task.id.rawValue)", directoryHint: .isDirectory)
        let settings = config.preferences.automationSettings
        guard let json = BrowserSitePolicy.contentRules(sites: settings.browserSites, block: task.record.portBlock,
                                                        blocked: blockedHosts(of: task)) else {
            session.applyRules(nil)
            return
        }
        // Stable across launches, so WebKit's store keeps one compiled list per distinct rule set.
        let identifier = "scope-agent-" + SHA256.hash(data: Data(json.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let store = WKContentRuleListStore.default()!
        let list: WKContentRuleList?
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            list = cached
        } else {
            do {
                list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            } catch {
                Log.app.error("agent browser rules did not compile: \(String(describing: error), privacy: .public)")
                list = nil
            }
        }
        session.applyRules(list)
    }

    /// *Block … for this task* on the pane's notice: the host joins the task's list, the rules follow at once.
    func blockForTask(_ host: String, session: BrowserSession) {
        guard let task = task(session.taskID) else { return }
        task.browserBlocked = BrowserSitePolicy.normalized(task.browserBlocked + [host])
        session.acknowledgedHosts.insert(host)
        Usage.click("browser.block-host", label: "Block a host for a task's agents")
        Task { await applyAgentRules(to: session, of: task) }
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
