import ScopeAssist
import ScopeCore
import SwiftUI

/// Settings ▸ Assist: which models may read the threads (spec §4.10), what they are allowed to decide, and what they
/// did today.
struct AssistSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.assist
        let prefs = model.config.preferences
        SettingsPage {
            SettingsSection("Models") {
                SettingsRow("Assist") {
                    ScopePicker("Assist", selection: preference(\.assist), title: Self.title(prefs.assist)) {
                        ForEach(AssistMode.allCases, id: \.self) { mode in
                            Text(Self.title(mode)).tag(mode)
                        }
                    }
                    .usageID("assist-mode", label: "Assist mode")
                }
                Text("""
                    On events only — a turn that ends, a question, a thread running for a while — the assistant reads the \
                    end of the terminal and answers with labels: what the agent is doing, whether it seems stuck, whether a \
                    notification is worth your attention. It never acts. The on-device model is Apple's, free and local; \
                    Haiku runs through `claude -p` with no tools, counts against your subscription, and is capped per day.
                    """)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("On-device model", value: engine.onDeviceAvailable ? "Available" : "Unavailable — \(engine.onDeviceUnavailableReason ?? "unknown")")
                SettingsRow("Haiku", value: engine.haikuAvailable ? "Available (Claude Code profile)" : "No profile declares a tool-free assist command")
                if prefs.assist == .onDeviceAndHaiku {
                    SettingsRow("Haiku calls per day") {
                        HStack(spacing: 8) {
                            Text("\(prefs.assistDailyCap)")
                                .foregroundStyle(Ink.primary)
                                .monospacedDigit()
                            ScopeStepper(value: prefs.assistDailyCap, range: Preferences.assistDailyCapRange) { value in
                                model.updatePreferences { $0.assistDailyCap = value }
                            }
                            .usageID("assist-daily-cap", label: "Haiku calls per day")
                        }
                    }
                }
            }
            SettingsSection("Decisions") {
                Toggle("Keep informational turn-ended notifications silent", isOn: preference(\.assistQuietsInformational))
                    .toggleStyle(.scope)
                    .usageID("assist-quiet-informational", label: "Quiet informational notifications")
                Toggle("Suggest archiving a task whose last reply looks final", isOn: preference(\.assistSuggestsArchive))
                    .toggleStyle(.scope)
                    .usageID("assist-suggest-archive", label: "Suggest archiving")
                Toggle("File a new task under one of the scope's topics", isOn: preference(\.assistPicksTopic))
                    .toggleStyle(.scope)
                    .usageID("assist-pick-topic", label: "Pick a topic for new tasks")
                Text("A thread the assistant reads as stuck shows *Seems stuck* in the sidebar and the Inbox, with a *Not stuck* answer that is remembered as a false positive.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Today") {
                SettingsRow("On-device calls", value: "\(engine.ledger.onDeviceCalls)" + latency(.onDevice))
                SettingsRow("Haiku calls", value: "\(engine.ledger.haikuCalls) of \(prefs.assistDailyCap)" + latency(.haiku))
                SettingsRow("Marked not stuck", value: "\(engine.ledger.falsePositives)")
                Text("Every decision is logged in the usage log by its id and tier only — never the text it read.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .usageArea("settings.assist")
    }

    private func latency(_ tier: AssistTier) -> String {
        guard let seconds = model.assist.lastLatency[tier] else { return "" }
        return " · last answer in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
    }

    static func title(_ mode: AssistMode) -> String {
        switch mode {
        case .off: "Off"
        case .onDevice: "On-device only"
        case .onDeviceAndHaiku: "On-device + Haiku"
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.config.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}
