import AppKit
import ScopeCore
import UserNotifications

/// Where `ScopeApp` parks the model so the AppKit delegate (created by the adaptor) can reach it.
@MainActor
enum AppServices {
    static var model: AppModel?
}

/// Finder / Dock / Services entry points and the quit sequence.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        TerminalKeyBindings.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Folders dropped on the Dock icon, or Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        addScopes(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
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
        let folders = directoriesOnly(urls)
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
    /// A click on the banner, "Go to Thread" or "See Delta": the app comes up on the thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let threadID = ThreadID(rawValue: response.notification.request.identifier)
        let showDelta = response.actionIdentifier == ThreadNotifier.seeDeltaAction
        guard let threadID else { return }
        await MainActor.run { AppServices.model?.reveal(thread: threadID, showDelta: showDelta) }
    }

    /// Nothing while frontmost: the sidebar dot and the badge already say it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
