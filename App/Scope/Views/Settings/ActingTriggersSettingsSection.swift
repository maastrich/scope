import ScopeCore
import SwiftUI

/// Settings ▸ Automatic actions: each trigger that acts on a thread, on or off, with how many times per hour it may
/// act on one thread before Scope stops and tells you.
struct ActingTriggersSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection("Automatic actions") {
            Text("Scope relaunches or tells a thread when its surroundings change. It never types into a turn at work or over what you are typing, acts once per failure, commit or batch of comments, and stops after the hourly cap — then notifies you. Each act shows on the thread's activity line and in the event journal.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ActingTrigger.allCases) { trigger in
                row(trigger)
            }
            if model.config.preferences.assist == .off {
                Text("Thread seems stuck needs the assistant (Settings ▸ Assistant): it acts on its verdict.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
            }
        }
    }

    private func row(_ trigger: ActingTrigger) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(trigger.title, isOn: Binding(
                    get: { model.config.preferences.actingTriggers[trigger].enabled },
                    set: { value in model.updatePreferences { $0.actingTriggers[trigger].enabled = value } }
                ))
                .toggleStyle(.scope)
                .usageID("trigger-\(trigger.rawValue)", label: "Automatic action: \(trigger.title)")
                Spacer()
                Stepper(value: Binding(
                    get: { model.config.preferences.actingTriggers[trigger].hourlyCap },
                    set: { value in
                        model.updatePreferences {
                            $0.actingTriggers[trigger] = ActingTriggerPreference(enabled: $0.actingTriggers[trigger].enabled, hourlyCap: value)
                        }
                    }
                ), in: ActingTriggerPreference.capRange) {
                    Text("\(model.config.preferences.actingTriggers[trigger].hourlyCap)× per hour")
                        .font(.scopeCaption)
                        .monospacedDigit()
                        .foregroundStyle(Ink.secondary)
                }
                .disabled(!model.config.preferences.actingTriggers[trigger].enabled)
            }
            Text(trigger.summary)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
