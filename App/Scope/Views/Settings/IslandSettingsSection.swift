import AppKit
import Intents
import SwiftUI
import ScopeCore

/// Settings › General › Island: whether the island under the notch shows, how it opens, on which screen, and what it
/// reveals.
struct IslandSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection("Island") {
            Toggle("Show the island under the notch", isOn: Binding(
                get: { model.islandEnabled },
                set: { value in model.updatePreferences { $0.island.enabled = value } }
            ))
            .toggleStyle(.scope)
            .usageID("island-enabled", label: "Show the island")
            SettingsRow("Opens") {
                ScopePicker("Opens", selection: island(\.opening), title: title(model.config.preferences.island.opening)) {
                    ForEach(IslandSettings.Opening.allCases, id: \.self) { Text(title($0)).tag($0) }
                }
                .usageID("island-opening", label: "Island opens")
            }
            SettingsRow("Screen") {
                ScopePicker("Screen", selection: screenChoice, title: screenTitle) {
                    Text("Active window").tag("activeWindow")
                    Text("Main display").tag("main")
                    Text("The one with the pointer").tag("pointer")
                    ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                        Text(name).tag("named:" + name)
                    }
                }
                .usageID("island-screen", label: "Island screen")
            }
            Toggle("Reveal a finished turn", isOn: island(\.alertsOnFinish)).toggleStyle(.scope)
            Toggle("Reveal a failed turn", isOn: island(\.alertsOnFailure)).toggleStyle(.scope)
            Toggle("Reveal a question, a permission or a plan", isOn: island(\.alertsOnRequest)).toggleStyle(.scope)
            Toggle("Play a sound with each reveal", isOn: island(\.playsSound)).toggleStyle(.scope)
            Text("The island shows the Claude Code threads at work, a dot per thread and the 5-hour limit; open, it answers a permission or a question and opens a thread in Scope. A reveal never shows for the thread you are looking at, nor while a Focus is on (\(focusStatus)) or the screen is locked. It sits on the screen of the window you are working in, whatever the app, and moves when you switch, never while it is open. On a screen without a notch it is a pill at the top. Off by default in a Debug build.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var focusStatus: String {
        switch model.island.quiet.focusAuthorization {
        case .authorized: "Scope may read it"
        case .notDetermined: "Scope has not asked to read it yet"
        default: "Scope may not read it: System Settings ▸ Privacy & Security ▸ Focus"
        }
    }

    private func title(_ opening: IslandSettings.Opening) -> String {
        switch opening {
        case .hover: "On hover"
        case .click: "On click"
        }
    }

    private var screenChoice: Binding<String> {
        Binding(
            get: {
                let island = model.config.preferences.island
                switch island.placement {
                case .activeWindow: return "activeWindow"
                case .main: return "main"
                case .pointer: return "pointer"
                case .named: return "named:" + (island.screenName ?? "")
                }
            },
            set: { tag in
                model.updatePreferences {
                    if tag == "activeWindow" { $0.island.placement = .activeWindow }
                    else if tag == "main" { $0.island.placement = .main }
                    else if tag == "pointer" { $0.island.placement = .pointer }
                    else {
                        $0.island.placement = .named
                        $0.island.screenName = String(tag.dropFirst("named:".count))
                    }
                }
            }
        )
    }

    private var screenTitle: String {
        let island = model.config.preferences.island
        switch island.placement {
        case .activeWindow: return "Active window"
        case .main: return "Main display"
        case .pointer: return "The one with the pointer"
        case .named: return island.screenName ?? "Main display"
        }
    }

    private func island<Value>(_ keyPath: WritableKeyPath<IslandSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.config.preferences.island[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0.island[keyPath: keyPath] = value } }
        )
    }
}
