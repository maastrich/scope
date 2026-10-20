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

    var body: some View {
        VStack(spacing: 0) {
            band
            Divider()
            if let session = model.currentBrowserTab {
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
            if let session = model.currentBrowserTab, session.url != nil {
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
            TabStrip(selection: selection, items: model.currentBrowserTabs.map { (value: $0.id, title: $0.tabTitle) })
            if let session = model.currentBrowserTab {
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

    private var selection: Binding<String> {
        Binding(
            get: { model.currentBrowserTab?.id ?? "" },
            set: { model.selectBrowserTab($0) }
        )
    }

    // MARK: Footer

    private var footer: some View {
        let scopeName = model.currentTask.flatMap { model.scope($0.scopeID)?.name } ?? "this scope"
        return HStack(spacing: 10) {
            Text("Your data store for \(scopeName) · apart from Safari and from agents")
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Cookies and storage of these pages are kept for every task of \(scopeName), in WebKit's store for Scope, and nowhere else. Web Inspector: Safari ▸ Develop ▸ this Mac.")
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
            return "Start the dev server in the task — on its own port with `--port $SCOPE_PORT` (\(model.currentTask?.record.portBlock.map { String($0.base) } ?? "the task's port")) — then try again.\n\(failure.message)"
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
