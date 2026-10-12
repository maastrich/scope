import AppKit
import Observation
#if !DEBUG
import Sparkle
#endif
import SwiftUI

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

    init(startingUpdater: Bool = true) {}

    func start() {}

    func checkForUpdates() {}
}

#else
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
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil, // Sparkle holds its delegates weakly: keep any delegate alive yourself.
            userDriverDelegate: nil
        )
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

    /// Starts the updater when it was created with `startingUpdater: false`.
    func start() { controller.startUpdater() }

    /// User-initiated check with Sparkle's standard UI ("Check for Updates…").
    func checkForUpdates() { controller.updater.checkForUpdates() }
}

#endif

/// Menu item for `CommandGroup(after: .appInfo)`. A dedicated view keeps the Observation tracking scope
/// (and therefore the enabled/disabled refresh of the menu item) confined to this button.
struct CheckForUpdatesButton: View {
    let updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
