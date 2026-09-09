import AppKit
import Observation
import Sparkle
import SwiftUI

/// Owns Sparkle's standard updater for the lifetime of the app (scheduled background checks driven by the
/// `SU*` keys of Info.plist, plus user-initiated checks from the menu) and mirrors
/// `SPUUpdater.canCheckForUpdates` into an `@Observable` property so SwiftUI can enable/disable the menu item.
///
/// Sparkle's public API is annotated `NS_SWIFT_UI_ACTOR` (= `@MainActor` in Swift), so this class is
/// `@MainActor` as well: the `ObservableObject` sample from Sparkle's documentation does not compile in
/// Swift 6 language mode ("cannot form key path to main actor-isolated property 'canCheckForUpdates'").
@MainActor
@Observable
final class UpdaterController {
    /// `true` while Sparkle accepts a user-initiated check (false during a check, a download or an install).
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// - Parameter startingUpdater: pass `false` to call `start()` yourself later (for example after onboarding).
    init(startingUpdater: Bool = true) {
        // A Debug build carries the release feed and `MARKETING_VERSION = 0.0.0`, so every published release
        // looks newer: a scheduled check replaces the developer's own build inside DerivedData, and the app
        // dies at the next launch while the bundle is half swapped. The updater never runs outside Release.
        #if DEBUG
        let shouldStart = false
        #else
        let shouldStart = startingUpdater
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: shouldStart,
            updaterDelegate: nil, // Sparkle holds its delegates weakly: keep any delegate alive yourself.
            userDriverDelegate: nil
        )
        #if DEBUG
        controller.updater.automaticallyChecksForUpdates = false
        #endif
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            // Sparkle mutates the property on the main thread, but the KVO closure is not statically
            // main-actor isolated: hop explicitly.
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// The underlying updater (feed URL, last check date, `checkForUpdatesInBackground()`, ...).
    var updater: SPUUpdater { controller.updater }

    /// Starts the updater when it was created with `startingUpdater: false`. No-op in Debug, where the
    /// updater must never run (see `init`); `canCheckForUpdates` then stays false and the menu item disabled.
    func start() {
        #if DEBUG
        return
        #else
        controller.startUpdater()
        #endif
    }

    /// User-initiated check with Sparkle's standard UI ("Check for Updates…").
    func checkForUpdates() { controller.updater.checkForUpdates() }
}

/// Menu item for `CommandGroup(after: .appInfo)`. A dedicated view keeps the Observation tracking scope
/// (and therefore the enabled/disabled refresh of the menu item) confined to this button.
struct CheckForUpdatesButton: View {
    let updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
