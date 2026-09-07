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
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { ScopeCommands(updater: updater) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
