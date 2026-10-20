import AppKit
import SwiftUI
import ScopeCore

/// The task's Browser pane in the reading column (spec §7): a band naming the task with one tab per server, an
/// address bar, the page, and a footer saying whose data store it is. A preview of what the task serves, beside
/// its terminal — not a browser for the rest of the web, which stays in the system's by default.
struct BrowserPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var leading: AnyView?
    var trailing: AnyView?
    @State private var showsConsole = false
    @State private var showsActions = false

    var body: some View {
        VStack(spacing: 0) {
            band
            Divider()
            if let task = model.currentTask, model.browser.showingComparison.contains(task.id),
               let comparison = model.browser.comparisons[task.id] {
                BrowserCompareView(comparison: comparison)
            } else if let session = model.currentBrowserTab {
                if session.kind == .agent {
                    BrowserAgentBand(session: session)
                    Divider()
                }
                BrowserAddressBar(session: session, block: model.currentTask?.record.portBlock)
                    .id(session.id)
                Divider()
                ZStack {
                    BrowserHost(session: session)
                        .id(session.id)
                    if let failure = session.failure {
                        BrowserFailureView(session: session, failure: failure)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if session.kind == .agent {
                        Rectangle().strokeBorder(Origin.agent.opacity(0.7), lineWidth: 2).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if session.kind == .agent, let host = session.externalHosts.last(where: { !session.acknowledgedHosts.contains($0) }) {
                        BrowserHostNotice(session: session, host: host)
                            .padding(16)
                            .transition(.opacity)
                    }
                }
                if showsActions, session.kind == .agent {
                    Divider()
                    BrowserActionLog(session: session)
                        .frame(height: 140)
                }
                if showsConsole {
                    Divider()
                    BrowserConsoleView(session: session)
                        .frame(height: 140)
                }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.currentBrowserTabs.map(\.id))
    }

    // MARK: Band

    private var band: some View {
        HStack(spacing: 8) {
            if let leading { leading }
            Image(systemName: "globe")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
            Text("Browser")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Ink.primary)
            if let task = model.currentTask {
                Text("· \(task.name)")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            tabs
            Spacer(minLength: 4)
            if let task = model.currentTask {
                if model.browser.comparing.contains(task.id) {
                    ProgressView().controlSize(.mini)
                        .help("Capturing both sides…")
                } else {
                    Button {
                        model.compareInPane(task)
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                    }
                    .help("Compare — this route on the base branch's server and on the task's, side by side")
                    .accessibilityLabel("Compare with the base branch")
                    .usageID("browser.compare", label: "Compare the base branch and the task")
                }
            }
            if let session = model.currentBrowserTab, session.url != nil, !showsComparison {
                Button {
                    model.openBrowserTabInSystem(session)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open this page in the system browser")
                .accessibilityLabel("Open in the system browser")
                .usageID("browser.open-in-system", label: "Open a browser tab in the system browser")
            }
            if let trailing {
                HStack(spacing: 2) { trailing }.fixedSize()
            }
        }
        .buttonStyle(.iconTight)
        .foregroundStyle(Ink.secondary)
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Surface.panel)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            TabStrip(selection: selection, items: model.currentBrowserTabs.map { (value: $0.id, title: $0.tabTitle) }
                     + (hasComparison ? [(value: Self.compareTab, title: "Compare")] : []))
            if let session = model.currentBrowserTab, !showsComparison {
                Button {
                    model.closeBrowserTab(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .help("Close this tab")
                .accessibilityLabel("Close this tab")
                .usageID("browser.close-tab", label: "Close a browser tab")
            }
            Button {
                if let task = model.currentTask { model.newBrowserTab(in: task) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .help("New tab, on the task's first server")
            .accessibilityLabel("New tab")
            .usageID("browser.new-tab", label: "New browser tab")
        }
        .fixedSize()
    }

    private static let compareTab = "compare"

    private var hasComparison: Bool {
        model.currentTask.map { model.browser.comparisons[$0.id] != nil } ?? false
    }

    private var showsComparison: Bool {
        model.currentTask.map { model.browser.showingComparison.contains($0.id) } ?? false
    }

    private var selection: Binding<String> {
        Binding(
            get: { showsComparison ? Self.compareTab : model.currentBrowserTab?.id ?? "" },
            set: { value in
                guard let task = model.currentTask else { return }
                if value == Self.compareTab {
                    model.browser.showComparison(true, of: task.id)
                } else {
                    model.selectBrowserTab(value)
                }
            }
        )
    }

    // MARK: Footer

    private var footer: some View {
        let scopeName = model.currentTask.flatMap { model.scope($0.scopeID)?.name } ?? "this scope"
        let session = model.currentBrowserTab
        let agent = session?.kind == .agent
        return HStack(spacing: 10) {
            if let session {
                Button {
                    showsConsole.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Console")
                        let errors = session.console.filter { $0.level == "error" }.count
                        if errors > 0 {
                            Text("\(errors)")
                                .foregroundStyle(PullRequestStyle.failing)
                        } else if !session.console.isEmpty {
                            Text("\(session.console.count)")
                        }
                    }
                    .font(.system(size: 10.5, weight: showsConsole ? .semibold : .regular))
                    .foregroundStyle(showsConsole ? Ink.primary : Ink.secondary)
                }
                .buttonStyle(.plain)
                .help("What the page logged: console.* and uncaught errors")
                .usageID("browser.console", label: "Browser console")
                if agent {
                    Button {
                        showsActions.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Actions")
                            if !session.actionLog.isEmpty { Text("\(session.actionLog.count)") }
                        }
                        .font(.system(size: 10.5, weight: showsActions ? .semibold : .regular))
                        .foregroundStyle(showsActions ? Ink.primary : Ink.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Every action the agents took in this tab, and how it ended")
                    .usageID("browser.actions", label: "Agent browser actions")
                }
                if let file = session.downloads.last {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } label: {
                        Label(file.lastPathComponent, systemImage: "arrow.down.circle")
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.secondary)
                    .help("Downloaded under Scope's home (\(file.deletingLastPathComponent().path)); click to reveal")
                }
            }
            Text(agent ? "Agent store" : "Store of \(scopeName) · apart from Safari and agents")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(agent
                      ? "The agents of this task browse on a data store of the task's own, removed when the task is archived: none of your sign-ins, none of your tabs."
                      : "Cookies and storage of these pages are kept for every task of \(scopeName), in WebKit's store for Scope, and nowhere else. Web Inspector: Safari ▸ Develop ▸ this Mac.")
            Spacer(minLength: 4)
            Text("⌘L address · ⌘R reload · ⌃⇧B toggles")
                .fixedSize()
                .help("⌘L and ⌘R while the page has the keyboard; ⌃⇧B shows and hides the pane")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Ink.tertiary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Surface.panel)
    }
}

/// Back, forward, reload, and the address: `task` and the origin for one of the task's servers, the path after it.
private struct BrowserAddressBar: View {
    @Environment(AppModel.self) private var model
    let session: BrowserSession
    let block: PortBlock?
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!session.canGoBack)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")
            Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!session.canGoForward)
                .help("Forward (⌘])")
                .accessibilityLabel("Forward")
            Button {
                session.isLoading ? session.stopLoading() : session.reload()
            } label: {
                Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(session.isLoading ? "Stop loading" : "Reload (⌘R)")
            .accessibilityLabel(session.isLoading ? "Stop loading" : "Reload")
            .usageID("browser.reload", label: "Reload a browser tab")
            field
        }
        .buttonStyle(.iconTight)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(Surface.ground)
        .onAppear { text = session.url?.absoluteString ?? "" }
        .onChange(of: session.url) { _, url in
            if !editing { text = url?.absoluteString ?? "" }
        }
        .onChange(of: session.addressFocusToken) { focused = true }
        .onChange(of: focused) { _, now in
            editing = now
            if !now { text = session.url?.absoluteString ?? "" }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            if let url = session.url, BrowserRoute.isTaskServer(url, block: block) {
                Text("task")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Surface.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .help("A port of this task's block: a server the task runs")
            }
            TextField("Address, or :port", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Ink.primary)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityLabel("Address")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(alignment: .bottom) {
            if session.isLoading, session.progress < 1 {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * max(0.05, session.progress), height: 2)
                }
                .frame(height: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
                .accessibilityHidden(true)
            }
        }
    }

    private func submit() {
        guard let url = BrowserRoute.url(fromAddress: text) else {
            NSSound.beep()
            return
        }
        Usage.click("browser.address", label: "Go to an address in the browser pane")
        session.load(url)
        focused = false
        session.webView.window?.makeFirstResponder(session.webView)
    }
}

/// The band over the agent's tab: which thread drives it and what it did last. The page is the agent's, on its
/// own store; the user watches, and their own tabs stay as they were.
private struct BrowserAgentBand: View {
    let session: BrowserSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
            if let activity = session.agentActivity {
                Text(activity.thread)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text("browser_\(activity.action)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(activity.at, style: .relative)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                    .fixedSize()
            } else {
                Text("Agent tab")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
            }
            if session.isStopped {
                Text("Stopped")
                    .font(.scopeCaption.weight(.semibold))
                Button("Let It Continue") { session.resumeAgents() }
                    .buttonStyle(.scopeSecondary)
                    .help("Agents may drive this browser again")
                    .usageID("browser.resume", label: "Resume the agent browser")
            } else {
                Button("Stop") { session.stopAgents() }
                    .buttonStyle(.scopeSecondary)
                    .keyboardShortcut(session.agentCallsInFlight > 0 ? KeyboardShortcut(.escape, modifiers: []) : nil)
                    .help(session.agentCallsInFlight > 0 ? "Stop the agent here (Esc): its running call ends, the next ones are refused"
                          : "Stop agents from driving this browser until you let them continue")
                    .usageID("browser.stop", label: "Stop the agent browser")
            }
        }
        .foregroundStyle(Origin.agent)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Origin.agent.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("An agent drives this tab")
    }
}

/// The agent went outside localhost: said, not asked. The page stays where it is; blocking takes effect at once,
/// for every page and subresource of this task's agent tab.
private struct BrowserHostNotice: View {
    @Environment(AppModel.self) private var model
    let session: BrowserSession
    let host: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text("The agent opened \(host)")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    session.acknowledgedHosts.insert(host)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.iconTight)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .foregroundStyle(Ink.primary)
            Text("Outside localhost, in the agent's own data store: none of your cookies, none of your tabs. Nothing waits on you; block the site if it should not go there.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Block \(host) for This Task") { model.blockForTask(host, session: session) }
                    .buttonStyle(.scopeSecondary)
                    .usageID("browser.block-host", label: "Block a host for a task's agents")
            }
        }
        .padding(12)
        .frame(maxWidth: 460)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Surface.stroke))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// The agents' actions in this tab, newest last: when, which thread, what, and how it ended.
private struct BrowserActionLog: View {
    let session: BrowserSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if session.actionLog.isEmpty {
                        Text("No action yet")
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.top, 6)
                    }
                    ForEach(session.actionLog) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.at, format: .dateTime.hour().minute().second())
                                .foregroundStyle(Ink.tertiary)
                            Text(entry.action)
                                .foregroundStyle(Origin.agent)
                                .frame(width: 70, alignment: .leading)
                            Text(entry.detail)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            Text(entry.outcome)
                                .foregroundStyle(entry.outcome.hasPrefix("refused") ? PullRequestStyle.failing : Ink.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.thread)
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .onChange(of: session.actionLog.count) {
                if let last = session.actionLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Surface.ground)
    }
}

/// Before and after, side by side at one viewport, the regions that differ outlined on the after side.
private struct BrowserCompareView: View {
    let comparison: BrowserStore.Comparison

    var body: some View {
        let result = comparison.result
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(comparison.path)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Ink.primary)
                Text("· \(result.width)×\(result.height) · same viewport · \(comparison.at.formatted(date: .omitted, time: .shortened))")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(result.summary)
                    .font(.scopeCaption.weight(.semibold))
                    .foregroundStyle(result.regions.isEmpty ? Ink.secondary : Color("WarningText"))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background((result.regions.isEmpty ? Fill.quiet : Color("WarningText").opacity(0.12)),
                                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Surface.panel)
            Divider()
            GeometryReader { proxy in
                let half = (proxy.size.width - 1) / 2
                HStack(spacing: 0) {
                    side(label: result.beforeWorktree ?? "before", url: result.before, image: comparison.before, regions: [], width: half)
                    Divider()
                    side(label: result.afterWorktree ?? "after", url: result.after, image: comparison.after, regions: result.regions, width: half)
                }
            }
        }
    }

    private func side(label: String, url: String, image: NSImage, regions: [ImageDiff.Region], width: CGFloat) -> some View {
        let scale = width / CGFloat(comparison.result.width)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(URL(string: url).map { "\($0.host ?? ""):\($0.port.map(String.init) ?? "")\($0.path)" } ?? url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            Divider()
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: CGFloat(comparison.result.height) * scale)
                    .overlay(alignment: .topLeading) {
                        ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color("WarningText"), lineWidth: 2)
                                .background(Color("WarningText").opacity(0.06))
                                .frame(width: CGFloat(region.width) * scale + 6, height: CGFloat(region.height) * scale + 6)
                                .offset(x: CGFloat(region.x) * scale - 3, y: CGFloat(region.y) * scale - 3)
                        }
                    }
            }
        }
        .frame(width: width)
    }
}

/// What the page logged, newest last, errors in red.
private struct BrowserConsoleView: View {
    let session: BrowserSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if session.console.isEmpty {
                        Text("Nothing logged yet")
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                            .padding(.top, 6)
                    }
                    ForEach(Array(session.console.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(symbol(line.level))
                                .foregroundStyle(color(line.level))
                                .frame(width: 10)
                            Text(line.text)
                                .foregroundStyle(line.level == "error" ? PullRequestStyle.failing
                                                 : line.level == "warn" ? Color("WarningText") : Ink.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let source = line.source {
                                Text(source).foregroundStyle(Ink.tertiary)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .id(index)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .onChange(of: session.console.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .background(Surface.ground)
    }

    private func symbol(_ level: String) -> String {
        switch level {
        case "error": "×"
        case "warn": "⚠"
        default: "›"
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": PullRequestStyle.failing
        case "warn": Color("WarningText")
        default: Ink.tertiary
        }
    }
}

/// What a failed load says over the page: nothing listening on a task port is the usual one, and it says how to
/// start a server there.
private struct BrowserFailureView: View {
    @Environment(AppModel.self) private var model
    let session: BrowserSession
    let failure: BrowserSession.Failure

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Ink.tertiary)
            Text(headline)
                .font(.scopeTitle)
                .foregroundStyle(Ink.primary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button("Try Again") { session.reload() }
                .buttonStyle(.scopeSecondary)
                .usageID("browser.retry", label: "Retry a failed page")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.ground)
    }

    private var isLocal: Bool { failure.url.map(BrowserRoute.isLocal) ?? false }

    private var headline: String {
        guard let url = failure.url else { return "This page could not be loaded" }
        if isLocal, let port = BrowserRoute.port(of: url) { return "Nothing answers on localhost:\(port)" }
        return "\(url.host ?? url.absoluteString) could not be loaded"
    }

    private var detail: String {
        if isLocal {
            return "Start the dev server in the task on its own port — --port $SCOPE_PORT, here \(model.currentTask?.record.portBlock.map { String($0.base) } ?? "the task's port") — then try again.\n\(failure.message)"
        }
        return failure.message
    }
}

/// Puts the session's long-lived web view in the pane, re-parented on a tab switch so the page, its scroll and its
/// history stay.
private struct BrowserHost: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
    }

    private func attach(to container: NSView) {
        let view = session.webView
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
