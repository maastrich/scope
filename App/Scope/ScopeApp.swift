import SwiftUI

@main
struct ScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    // Created once, with the app. Sparkle starts here (SUEnableAutomaticChecks in Info.plist drives the
    // scheduled checks; nothing to call). Pass `startingUpdater: false` and call `updater.start()` later
    // to defer the first check (e.g. after onboarding).
    @State private var updater = UpdaterController()

    init() {
        let model = AppModel(env: AppEnvironment.live())
        _model = State(initialValue: model)
        AppServices.model = model
    }

    var body: some Scene {
        Window("Scope", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 600)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            // View ▸ Show / Hide Sidebar and its ⌃⌘S. Without it the chord listed in the shortcut sheet did nothing.
            SidebarCommands()
            ScopeCommands(updater: updater)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: menuBarExtraShown) {
            MenuBarExtraMenu()
                .environment(model)
        } label: {
            // The petal-ring template glyph; while threads wait, the count badge replaces it so the number stays legible.
            let waiting = model.waitingThreads.count
            if waiting > 0 {
                Image(systemName: "\(min(waiting, 50)).circle.fill")
            } else {
                Image("MenuBarIcon")
            }
        }
    }

    private var menuBarExtraShown: Binding<Bool> {
        Binding(
            get: { model.config.preferences.showMenuBarExtra },
            set: { value in
                // MenuBarExtra writes the binding on every scene update: only a real change reaches the config.
                guard value != model.config.preferences.showMenuBarExtra else { return }
                model.updatePreferences { $0.showMenuBarExtra = value }
            }
        )
    }
}
