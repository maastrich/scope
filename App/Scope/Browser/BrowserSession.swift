import AppKit
import Foundation
import ScopeControl
import ScopeCore
import ScopeTasks
import WebKit

/// One tab of a task's Browser pane: a `WKWebView` on a data store — the user's for the scope, or the agents' for the
/// task — and what the band and the address bar draw from it (title, URL, history, loading, the last failure, the
/// console).
@MainActor
@Observable
final class BrowserSession: Identifiable {
    let id: String
    let taskID: TaskID
    /// The WebKit store identifier (`BrowserStoreID`), fixed for the view's life.
    let storeID: UUID
    let kind: Kind

    enum Kind {
        /// A tab the user opened, on the scope's store: their sign-ins.
        case user
        /// The tab the task's agents drive, on the task's own store: none of the user's cookies.
        case agent
    }

    /// What an agent last did here, for the band that says an agent is driving.
    struct AgentActivity: Equatable {
        var thread: String
        var action: String
        var at: Date
    }

    private(set) var agentActivity: AgentActivity?
    /// Agent calls on this tab still running: the band offers Stop (and Esc) while there are some.
    private(set) var agentCallsInFlight = 0
    /// The user stopped the agents here: running calls end and new ones are refused until they resume.
    private(set) var isStopped = false
    /// Every agent action, newest last, for the journal of the pane.
    private(set) var actionLog: [ActionEntry] = []
    /// Hosts outside the loopback the agent's pages went to, in order; the pane shows the newest unacknowledged.
    private(set) var externalHosts: [String] = []
    var acknowledgedHosts: Set<String> = []
    /// Files the pages downloaded, under `SCOPE_HOME/browser/downloads/<task>/`.
    private(set) var downloads: [URL] = []
    /// Where a download goes; set by the model, which knows the home.
    @ObservationIgnored var downloadsFolder: URL?
    /// Requests kept since the page opened (`network`), capped like the console.
    private(set) var network: [BrowserNetworkEntry] = []
    @ObservationIgnored var networkReadByAgent = 0
    @ObservationIgnored private var networkDropped = 0
    @ObservationIgnored private var seenResources: Set<String> = []
    @ObservationIgnored fileprivate var pendingDownloads: [ObjectIdentifier: URL] = [:]

    struct ActionEntry: Identifiable, Equatable {
        let id = UUID()
        var at: Date
        var thread: String
        var action: String
        var detail: String
        var outcome: String
    }
    /// Everything the page logged since it opened, capped (`consoleCap`).
    private(set) var console: [BrowserConsoleLine] = []
    /// How many of `console` an agent has read: `scope_browser_console` answers with what comes after.
    @ObservationIgnored var consoleReadByAgent = 0
    @ObservationIgnored private var consoleDropped = 0
    static let consoleCap = 500

    private(set) var title = ""
    private(set) var url: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    /// The last navigation that failed, with WebKit's reason; cleared by the next one that commits.
    private(set) var failure: Failure?
    /// Bumped to put the keyboard in the address bar (⌘L, a new tab).
    private(set) var addressFocusToken = 0

    struct Failure: Equatable {
        var url: URL?
        var message: String
    }

    /// The tab's URL changed: the store keeps `BrowserTabs` in step.
    @ObservationIgnored var onNavigate: (@MainActor (BrowserSession, URL?) -> Void)?
    /// A page asked for a new window (`target=_blank`, `window.open`).
    @ObservationIgnored var onOpenWindow: (@MainActor (BrowserSession, URL) -> Void)?

    @ObservationIgnored private var _webView: BrowserWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private lazy var delegate = BrowserSessionDelegate(session: self)

    init(taskID: TaskID, storeID: UUID, url: URL?, kind: Kind = .user) {
        self.id = UUID().uuidString
        self.taskID = taskID
        self.storeID = storeID
        self.url = url
        self.kind = kind
    }

    /// Created on first access — a view costs a WebContent process — and loaded with the tab's URL.
    var webView: BrowserWebView {
        if let _webView { return _webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserScripts.consoleRelay, injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: true, in: .page))
        configuration.userContentController.add(ConsoleRelay(session: self), contentWorld: .page, name: BrowserScripts.consoleHandler)
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserScripts.networkRelay, injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: true, in: .page))
        configuration.userContentController.add(NetworkRelay(session: self), contentWorld: .page, name: BrowserScripts.networkHandler)
        if let rules = pendingRules { configuration.userContentController.add(rules) }
        // An agent's tab may never be on screen: it still lays out at a desktop size, so a screenshot shows the page
        // as a person would see it.
        let view = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        // Safari ▸ Develop ▸ <this Mac> lists the page: the Web Inspector, its console and network, for the human.
        view.isInspectable = true
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.session = self
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.urlChanged(view.url) }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
        ]
        _webView = view
        if let url { view.load(URLRequest(url: url)) }
        return view
    }

    var hasView: Bool { _webView != nil }

    /// `:41000` until the page names itself; the agent's tab says so.
    var tabTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if !trimmed.isEmpty {
            name = trimmed.count > 24 ? String(trimmed.prefix(23)) + "…" : trimmed
        } else {
            name = url.map(BrowserRoute.shortTitle) ?? "New tab"
        }
        return kind == .agent ? "Agent · " + name : name
    }

    // MARK: Agent

    func noteAgent(thread: String, action: String) {
        agentActivity = AgentActivity(thread: thread, action: action, at: .now)
    }

    /// Navigates and waits until the page stops loading, `timeout` at most. `false` when it still loads.
    func loadAndWait(_ url: URL, timeout: Duration = .seconds(30)) async -> Bool {
        _ = webView
        load(url)
        return await waitUntilLoaded(timeout: timeout)
    }

    func waitUntilLoaded(timeout: Duration = .seconds(30)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        // The load may not have started yet when this is first asked.
        try? await Task.sleep(for: .milliseconds(150))
        while clock.now < deadline {
            if !(_webView?.isLoading ?? false) {
                // A frame for scripts that render on load (a dev server's client bundle).
                try? await Task.sleep(for: .milliseconds(250))
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    enum PageError: Error {
        case unreadable(String)
    }

    /// The page, read from the isolated world (`BrowserScripts.readPage`).
    func readPage() async throws -> BrowserPage {
        let raw = try await webView.evaluateJavaScript(BrowserScripts.readPage, in: nil, contentWorld: BrowserScripts.world)
        guard let json = raw as? String, let page = try? JSONDecoder().decode(BrowserPage.self, from: Data(json.utf8)) else {
            throw PageError.unreadable("the page could not be read")
        }
        return page
    }

    /// The viewport as JPEG, at most `maxWidth` pixels wide.
    func snapshotJPEG(maxWidth: CGFloat = 1280) async throws -> (data: Data, width: Int, height: Int) {
        let view = webView
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PageError.unreadable("the snapshot is empty")
        }
        let scale = min(1, maxWidth / CGFloat(cgImage.width))
        let width = max(1, Int(CGFloat(cgImage.width) * scale))
        let height = max(1, Int(CGFloat(cgImage.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PageError.unreadable("no context to scale the snapshot")
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw PageError.unreadable("the snapshot could not be encoded")
        }
        return (data, width, height)
    }

    // MARK: Agent calls

    /// Runs one agent call, counted for the band's Stop, logged in the journal.
    func agentCall<T>(thread: String, action: String, detail: String, _ body: () async -> (T, String)) async -> T {
        agentCallsInFlight += 1
        noteAgent(thread: thread, action: action)
        let entry = ActionEntry(at: .now, thread: thread, action: action, detail: detail, outcome: "…")
        actionLog.append(entry)
        if actionLog.count > 200 { actionLog.removeFirst(actionLog.count - 200) }
        let (value, outcome) = await body()
        agentCallsInFlight -= 1
        if let index = actionLog.firstIndex(where: { $0.id == entry.id }) { actionLog[index].outcome = outcome }
        return value
    }

    /// Stop: the agents' running calls end, new ones are refused, the page stops loading.
    func stopAgents() {
        isStopped = true
        _webView?.stopLoading()
    }

    func resumeAgents() {
        isStopped = false
    }

    /// The content rule list in force on the tab (`BrowserSitePolicy.contentRules`), replacing the previous one.
    @ObservationIgnored private var pendingRules: WKContentRuleList?
    func applyRules(_ list: WKContentRuleList?) {
        pendingRules = list
        guard let controller = _webView?.configuration.userContentController else { return }
        controller.removeAllContentRuleLists()
        if let list { controller.add(list) }
    }

    /// Runs `body` in the reader's world with `arguments`; the decoded dictionary it returned.
    func callInWorld(_ body: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: BrowserScripts.world)
        return value as? [String: Any] ?? [:]
    }

    /// Waits for a selector or a text — or, with neither, for the page to stop loading and request nothing for half
    /// a second. `false` on timeout or when the user stops the agents.
    func waitFor(selector: String?, text: String?, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastCount = -1
        var quietSince: ContinuousClock.Instant?
        while clock.now < deadline, !isStopped {
            let probe = (try? await callInWorld(BrowserScripts.probe, ["selector": selector ?? "", "text": text ?? ""])) ?? [:]
            if selector?.isEmpty == false || text?.isEmpty == false {
                if probe["found"] as? Bool == true { return true }
            } else {
                let count = probe["resources"] as? Int ?? 0
                let loading = _webView?.isLoading ?? false
                if !loading, count == lastCount {
                    if let since = quietSince, clock.now - since >= .milliseconds(500) { return true }
                    if quietSince == nil { quietSince = clock.now }
                } else {
                    quietSince = nil
                }
                lastCount = count
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// The resource timeline read into `network`, each entry once.
    func collectResources() async {
        guard hasView, let value = try? await webView.callAsyncJavaScript(BrowserScripts.resources, arguments: [:], in: nil,
                                                                           contentWorld: BrowserScripts.world),
              let entries = value as? [[String: Any]] else { return }
        for entry in entries {
            guard let url = entry["url"] as? String else { continue }
            let key = "\(url)|\(entry["start"] as? Double ?? 0)"
            guard seenResources.insert(key).inserted else { continue }
            record(BrowserNetworkEntry(url: url, type: entry["type"] as? String ?? "other", milliseconds: entry["ms"] as? Int))
        }
    }

    func networkForAgent(all: Bool) -> [BrowserNetworkEntry] {
        let start = all ? 0 : max(0, networkReadByAgent - networkDropped)
        networkReadByAgent = networkDropped + network.count
        return Array(network[min(start, network.count)...])
    }

    fileprivate func record(_ entry: BrowserNetworkEntry) {
        network.append(entry)
        if network.count > Self.consoleCap {
            network.removeFirst(network.count - Self.consoleCap)
            networkDropped += 1
        }
        if kind == .agent, let url = URL(string: entry.url) { noteHost(url) }
    }

    /// A host outside the loopback an agent's page went to: shown, never asked about.
    fileprivate func noteHost(_ url: URL) {
        guard kind == .agent, BrowserRoute.isWeb(url), !BrowserRoute.isLocal(url), let host = url.host?.lowercased(),
              !externalHosts.contains(host) else { return }
        externalHosts.append(host)
    }

    fileprivate func downloaded(_ file: URL) {
        downloads.append(file)
    }

    /// The lines an agent has not read yet, or every line kept; marks them read.
    func consoleForAgent(all: Bool) -> [BrowserConsoleLine] {
        let start = all ? 0 : max(0, consoleReadByAgent - consoleDropped)
        consoleReadByAgent = consoleDropped + console.count
        return Array(console[min(start, console.count)...])
    }

    fileprivate func logged(level: String, text: String, source: String?) {
        console.append(BrowserConsoleLine(level: level, text: text, source: source, at: .now))
        if console.count > Self.consoleCap {
            console.removeFirst(console.count - Self.consoleCap)
            consoleDropped += 1
        }
    }

    func load(_ url: URL) {
        failure = nil
        self.url = url
        if let _webView {
            _webView.load(URLRequest(url: url))
        }
        onNavigate?(self, url)
    }

    func goBack() { _webView?.goBack() }
    func goForward() { _webView?.goForward() }

    func reload() {
        failure = nil
        if let _webView, _webView.url != nil {
            _webView.reload()
        } else if let url {
            load(url)
        }
    }

    func stopLoading() { _webView?.stopLoading() }

    func focusAddress() { addressFocusToken += 1 }

    /// The tab is closed, or its task archived: the page stops and the view goes, taking its WebContent process.
    func tearDown() {
        observations.removeAll()
        guard let view = _webView else { return }
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.session = nil
        view.removeFromSuperview()
        _webView = nil
    }

    fileprivate func urlChanged(_ new: URL?) {
        guard let new, new != url else { return }
        url = new
        onNavigate?(self, new)
    }

    fileprivate func committed() {
        failure = nil
    }

    fileprivate func failed(_ error: Error, url failing: URL?) {
        let error = error as NSError
        // A navigation replaced by another (a click during a load) is not a failure worth a page.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return } // frame load interrupted (a download, a policy)
        failure = Failure(url: failing ?? url, message: error.localizedDescription)
    }

    fileprivate func openWindow(_ url: URL) {
        onOpenWindow?(self, url)
    }
}

/// The web view of a tab, with the pane's keys while the keyboard is in the page: ⌘L the address bar, ⌘R reload,
/// ⌘[ / ⌘] history. The window offers its views a key equivalent before the menu does, so the app's own ⌘R
/// (Refresh Scope) still answers everywhere else.
final class BrowserWebView: WKWebView {
    weak var session: BrowserSession?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let session, hasKeyboard,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "l": session.focusAddress()
        case "r": session.reload()
        case "[": session.goBack()
        case "]": session.goForward()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private var hasKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }
}

/// Receives the console relay's posts. Weak to the session: the content controller keeps its handlers alive.
private final class ConsoleRelay: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?

    init(session: BrowserSession) {
        self.session = session
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
        let level = (body["level"] as? String).flatMap { ["log", "info", "warn", "error", "debug"].contains($0) ? $0 : nil } ?? "log"
        let source = body["source"] as? String
        MainActor.assumeIsolated { session?.logged(level: level, text: String(text.prefix(4000)), source: source) }
    }
}

/// Receives the network relay's posts (fetch and XHR, with their status).
private final class NetworkRelay: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?

    init(session: BrowserSession) {
        self.session = session
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let url = body["url"] as? String else { return }
        let entry = BrowserNetworkEntry(url: String(url.prefix(2000)), type: body["type"] as? String ?? "fetch",
                                        method: body["method"] as? String, status: body["status"] as? Int,
                                        milliseconds: body["ms"] as? Int, failed: body["failed"] as? Bool ?? false)
        MainActor.assumeIsolated { session?.record(entry) }
    }
}

/// WebKit's delegates for one session, kept apart so the session stays a plain observable model.
private final class BrowserSessionDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var session: BrowserSession?

    init(session: BrowserSession) {
        self.session = session
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated { session?.committed() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        MainActor.assumeIsolated { session?.failed(error, url: failing) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { session?.failed(error, url: nil) }
    }

    /// `target=_blank` and `window.open`: a tab of the pane rather than a window nobody would find.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            MainActor.assumeIsolated { session?.openWindow(url) }
        }
        return nil
    }

    /// Links to anything but the web (`mailto:`, `vscode:`, an app's scheme) go to the system, as Safari would.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url {
            MainActor.assumeIsolated { session?.noteHost(url) }
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    /// What WebKit cannot show is a download, as in Safari: it lands under Scope's home, never in the user's folders.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(navigationResponse.canShowMIMEType && !attachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        MainActor.assumeIsolated {
            guard let folder = session?.downloadsFolder else { return completionHandler(nil) }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = suggestedFilename.replacingOccurrences(of: "/", with: "_")
            var target = folder.appending(path: name)
            var counter = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                target = folder.appending(path: ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
                counter += 1
            }
            completionHandler(target)
            session?.pendingDownloads[ObjectIdentifier(download)] = target
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            guard let session, let file = session.pendingDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            session.downloaded(file)
        }
    }
}
