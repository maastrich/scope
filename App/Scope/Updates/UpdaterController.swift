import AppKit
import Observation
import ScopeCore
#if !DEBUG
import Sparkle
#endif
import SwiftUI
import UserNotifications

/// A release Sparkle has downloaded, verified and staged: Scope installs it on its next quit, or right away
/// through `UpdaterController.installAndRelaunch()`.
struct ReadyUpdate: Equatable, Sendable {
    /// The marketing version (`1.2.3`), what the band and the menu show.
    let version: String
}

#if DEBUG
/// The updater of a Debug build: there is none.
///
/// A Debug build is version `0.0.0`, so every published release looks newer. With the release feed in reach, a
/// check replaced the developer's own build inside DerivedData with the installed app, and it died at the next
/// launch while the bundle was half swapped. Turning the updater off at runtime left `SPUStandardUpdaterController`
/// constructed and `checkForUpdates()` one palette command away, so Sparkle is not compiled into this
/// configuration at all: no import, no controller, and `SUFeedURL` is empty in the Debug Info.plist
/// (`SCOPE_UPDATE_FEED_URL` in project.yml).
@MainActor
@Observable
final class UpdaterController {
    /// Always `false`: "Check for Updates…" stays disabled.
    let canCheckForUpdates = false
    /// Always `nil`: nothing is ever staged.
    let readyUpdate: ReadyUpdate? = nil
    /// Never shown.
    var bandShown: Bool { false }

    init(startingUpdater: Bool = true) {}

    func start() {}

    func checkForUpdates() {}

    func installAndRelaunch() {}

    func dismissBand() {}
}

#else
/// Owns Sparkle's standard updater for the lifetime of the app and keeps a release moving on its own: the
/// scheduled checks driven by the `SU*` keys of Info.plist (hourly), a check when the app comes to the front or
/// the Mac wakes, and the background download Sparkle stages for its next quit (`SUAutomaticallyUpdate`).
///
/// What it never does is relaunch Scope by itself. A relaunch hangs up every running thread, so a staged
/// update is only *offered* — `readyUpdate` feeds a band in the window and "Restart to Update" in the Scope
/// menu — and installs when the owner quits, whenever that is. `canCheckForUpdates` mirrors
/// `SPUUpdater.canCheckForUpdates` into an `@Observable` property so SwiftUI can enable/disable the menu item.
///
/// Sparkle's public API is annotated `NS_SWIFT_UI_ACTOR` (= `@MainActor` in Swift), so this class is
/// `@MainActor` as well: the `ObservableObject` sample from Sparkle's documentation does not compile in
/// Swift 6 language mode ("cannot form key path to main actor-isolated property 'canCheckForUpdates'").
@MainActor
@Observable
final class UpdaterController {
    /// `true` while Sparkle accepts a user-initiated check (false during a check, a download or an install —
    /// and while an update is staged, since the stalled cycle counts as a session).
    private(set) var canCheckForUpdates = false

    /// The release staged for the next quit, once Sparkle has downloaded and verified it.
    private(set) var readyUpdate: ReadyUpdate?

    /// The band in the window is closable; the menu item stays, and the update still installs on quit.
    private(set) var bandDismissed = false

    var bandShown: Bool { readyUpdate != nil && !bandDismissed }

    /// A check on activation or wake is skipped when the last one is younger than this. Sparkle's scheduler
    /// already runs hourly; this only catches the owner coming back to Scope soon after a release.
    static let activationCheckInterval: TimeInterval = 15 * 60

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Sparkle's "install now" for the staged update: terminates Scope, swaps the bundle, relaunches. Kept
    /// until pressed; invokable again if the owner cancels the quit (Sparkle ≥ 2.3).
    @ObservationIgnored private var immediateInstall: (() -> Void)?

    /// - Parameter startingUpdater: pass `false` to call `start()` yourself later (for example after onboarding).
    init(startingUpdater: Bool = true) {
        let delegate = UpdaterDelegate()
        self.delegate = delegate // Sparkle holds its delegates weakly: keep it alive here.
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        delegate.owner = self
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            // Sparkle mutates the property on the main thread, but the KVO closure is not statically
            // main-actor isolated: hop explicitly.
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInBackgroundIfStale() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInBackgroundIfStale() }
        })
    }

    /// The underlying updater (feed URL, last check date, `checkForUpdatesInBackground()`, ...).
    var updater: SPUUpdater { controller.updater }

    /// Starts the updater when it was created with `startingUpdater: false`.
    func start() { controller.startUpdater() }

    /// User-initiated check with Sparkle's standard UI ("Check for Updates…").
    func checkForUpdates() { controller.updater.checkForUpdates() }

    /// Installs the staged update now: Scope quits (the usual "threads are running" confirmation applies),
    /// Sparkle swaps the bundle and relaunches it. Nothing happens without a staged update.
    func installAndRelaunch() {
        guard let immediateInstall else { return }
        AppServices.stopReason = .update
        immediateInstall()
    }

    func dismissBand() { bandDismissed = true }

    /// A silent check unless one ran in the last `activationCheckInterval`, one is in progress, or an update
    /// is already staged (the cycle is stalled on purpose then; the next launch picks up what came after).
    private func checkInBackgroundIfStale() {
        guard readyUpdate == nil, !updater.sessionInProgress else { return }
        if let last = updater.lastUpdateCheckDate, Date().timeIntervalSince(last) < Self.activationCheckInterval { return }
        updater.checkForUpdatesInBackground()
    }

    /// Sparkle staged `item` and will install it at the next quit; `install` installs it now instead.
    fileprivate func updateReady(_ item: SUAppcastItem, install: @escaping () -> Void) {
        immediateInstall = install
        bandDismissed = false
        readyUpdate = ReadyUpdate(version: item.displayVersionString)
        if !NSApplication.shared.isActive {
            Self.notify(version: item.displayVersionString)
        }
    }

    /// One notification, replaced by the next release: the owner is elsewhere, the band waits in the window.
    private static func notify(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Scope \(version) is ready"
        content.body = "Restart Scope to update. Or not: it installs when you quit."
        let request = UNNotificationRequest(identifier: "update-ready", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else { return }
                try await center.add(request)
            } catch {
                Log.app.warning("update notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// `SPUUpdaterDelegate` lives on its own object: `UpdaterController` is `@Observable`, and an `NSObject`
/// subclass with the macro's synthesized storage is more trouble than this indirection.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var owner: UpdaterController?

    /// `true` stalls Sparkle's cycle with the update staged: no dialog from Sparkle, no "impatient" reminder,
    /// install on quit — or now, through the handler, when the owner asks.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let owner else { return false }
        owner.updateReady(item, install: immediateInstallHandler)
        return true
    }
}

#endif

/// Menu item for `CommandGroup(after: .appInfo)`. A dedicated view keeps the Observation tracking scope
/// (and therefore the enabled/disabled refresh of the menu item) confined to this button. With an update
/// staged, Sparkle refuses a new check anyway, so the item becomes the way to install it.
struct CheckForUpdatesButton: View {
    let updater: UpdaterController

    var body: some View {
        if let ready = updater.readyUpdate {
            Button("Restart to Update to \(ready.version)…") { updater.installAndRelaunch() }
        } else {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
