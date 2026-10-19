import AppKit
import ScopeCore
import UserNotifications

/// Where `ScopeApp` parks the model so the AppKit delegate (created by the adaptor) can reach it.
@MainActor
enum AppServices {
    static var model: AppModel?
    /// ⇧ held while the app opened: skip the auto-relaunch of threads this once (the macOS gesture for "open without
    /// restoring"). Read as early as AppKit allows; `bootstrap` looks again in case the key went down a moment late.
    static var shiftHeldAtLaunch = false
}

/// Finder / Dock / Services entry points and the quit sequence.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingOpen: [URL] = []
    /// `scope://` links that arrived before the model existed (a cold launch from a link).
    private var pendingLinks: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppServices.shiftHeldAtLaunch = NSEvent.modifierFlags.contains(.shift)
        // Taken before SwiftUI's own URL handling, which would open a new window for the link rather than hand it
        // to the model.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        guard let model = AppServices.model else {
            pendingLinks.append(url)
            return
        }
        Task { await model.open(url: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        TerminalKeyBindings.install()
        AppServices.model?.startGlobalHotkeys()
        #if DEBUG
        // `SCOPE_QUICK_PANEL=ask|inbox` opens the quick panel shortly after launch: a throwaway instance driven from a
        // terminal has no hand on the keyboard to press the hotkey.
        if let tab = ProcessInfo.processInfo.environment["SCOPE_QUICK_PANEL"].flatMap(QuickPanel.Tab.init(rawValue:)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppServices.model?.showQuickPanel(tab: tab) }
        }
        // `SCOPE_APPEARANCE=dark|light` pins the instance's appearance, for screenshots of both without touching the system.
        if let name = ProcessInfo.processInfo.environment["SCOPE_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Folders dropped on the Dock icon, or Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        addScopes(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let model = AppServices.model, !pendingLinks.isEmpty {
            let links = pendingLinks
            pendingLinks = []
            Task { for link in links { await model.open(url: link) } }
        }
        AppServices.model?.clearNotifications(for: AppServices.model?.selectedThreadID)
        Self.refocusTerminal()
    }

    /// Makes the current terminal first responder again so typing resumes without a click.
    ///
    /// It has to insist. SwiftUI gives the keyboard to the sidebar's `List` *after* the click that changed the
    /// selection is processed, so a single `makeFirstResponder` loses the race and the terminal never gets the
    /// keys. Rather than guess at the right delay, each attempt checks whether the terminal actually holds the
    /// focus and takes it back if not, a bounded number of times.
    static func refocusTerminal(attemptsLeft: Int = 4) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let container = firstTerminalContainer(in: window.contentView) else { return }
        container.focusHostedView()
        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  let container = firstTerminalContainer(in: window.contentView),
                  !container.holdsFirstResponder(of: window)
            else { return }
            refocusTerminal(attemptsLeft: attemptsLeft - 1)
        }
    }


    private static func firstTerminalContainer(in view: NSView?) -> TerminalHostContainer? {
        guard let view else { return nil }
        if let container = view as? TerminalHostContainer { return container }
        for subview in view.subviews {
            if let found = firstTerminalContainer(in: subview) { return found }
        }
        return nil
    }

    // MARK: Services ("Open in Scope" in Finder's Services menu)

    @objc func openInScope(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No folder in the selection." as NSString
            return
        }
        NSApp.activate()
        addScopes(urls)
    }

    private func addScopes(_ urls: [URL]) {
        // Finder hands over files too; only directories can become scopes.
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !folders.isEmpty else { return }
        guard let model = AppServices.model else {
            pendingOpen.append(contentsOf: folders)
            return
        }
        let batch = pendingOpen + folders
        pendingOpen = []
        Task { await model.addScopes(batch) }
    }

    // MARK: Quit

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppServices.model else { return .terminateNow }
        if case .askUser(let running) = model.prepareForTermination() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(running) \(running == 1 ? "thread is" : "threads are") running. Quit and hang \(running == 1 ? "it" : "them") up?"
            alert.informativeText = "Each running process receives SIGHUP, as if its terminal window closed."
                + (model.config.preferences.autoRelaunchThreads
                    ? " \(running == 1 ? "It starts" : "They start") again when Scope reopens, resuming the driver session when there is one."
                    : "")
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task {
            await model.terminateNow()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: Notifications (spec §4.7)

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// A click on the banner, "Go to Thread" or "See Delta": the app comes up on the thread. Reply stays in the
    /// background and types the answer into the thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let threadID = ThreadID(rawValue: response.notification.request.identifier)
        let action = response.actionIdentifier
        let showDelta = action == ThreadNotifier.seeDeltaAction
        guard let threadID else { return }
        if action == ThreadNotifier.replyAction {
            // Only plain values cross to the main actor: the response is not `Sendable`.
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            await MainActor.run {
                Usage.register("notification.reply", label: "Reply")
                Usage.record(.notification, "notification.reply", source: .notification)
                AppServices.model?.reply(text, to: threadID)
            }
            return
        }
        if action == ThreadNotifier.notBlockingAction {
            await MainActor.run {
                Usage.register("notification.not-blocking", label: "Not blocking")
                Usage.record(.notification, "notification.not-blocking", source: .notification)
                AppServices.model?.markNotBlocking(threadID)
            }
            return
        }
        await MainActor.run {
            let id = switch action {
            case UNNotificationDefaultActionIdentifier: "notification.open"
            case ThreadNotifier.goToThreadAction: "notification.go-to-thread"
            case ThreadNotifier.seeDeltaAction: "notification.see-delta"
            default: "notification.other"
            }
            Usage.register(id, label: id == "notification.open" ? "Banner" : nil)
            Usage.record(.notification, id, source: .notification)
            Usage.attributed { AppServices.model?.reveal(thread: threadID, showDelta: showDelta) }
        }
    }

    /// Nothing while frontmost: the sidebar dot and the badge already say it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
