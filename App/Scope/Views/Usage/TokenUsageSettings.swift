import SwiftUI
import ScopeControl
import ScopeCore

/// Settings ▸ General ▸ Usage: the sidebar's meter (plan limits first, tokens under them), an optional token budget of
/// the user's own, the API-equivalent cost.
struct TokenUsageSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var budgetText = ""
    @FocusState private var budgetFocused: Bool

    var body: some View {
        SettingsSection("Usage") {
            Toggle("Show the usage meter at the bottom of the sidebar", isOn: preference(\.showTokenMeter))
                .toggleStyle(.scope)
                .usageID("show-token-meter", label: "Show the usage meter at the bottom of the sidebar")
            SettingsRow("Token budget per 5 h", caption: "Optional, for an API key: turns the token count into a gauge against your own figure, e.g. 20M.") {
                TextField("Budget", text: $budgetText, prompt: Text("none"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospacedDigit())
                    .focused($budgetFocused)
                    .onSubmit(commitBudget)
                    .onChange(of: budgetFocused) { _, focused in if !focused { commitBudget() } }
                    .scopeFieldBox(focused: budgetFocused, height: 22)
                    .frame(width: 120)
                    .usageID("token-budget", label: "Token budget per 5 h")
            }
            Toggle("Show the API-equivalent cost", isOn: preference(\.showAPICost))
                .toggleStyle(.scope)
                .usageID("show-api-cost", label: "Show the API-equivalent cost")
            Text("With a Pro or Max subscription the meter leads with the share used of each limit — the 5-hour session, the week, a model's week when the plan has one — and when it resets, as Claude Code reports them to its status line: each Claude Code thread Scope opens relays that status line to the app before running your own, which keeps showing. Your ~/.claude settings are not modified; a thread opened while the meter was off needs a relaunch to report. Tokens are counted from the threads' transcripts, subagents and cache reads included; the cost is what they would cost at API list prices, not what a subscription bills.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { budgetText = Self.text(model.config.preferences.tokenBudgetPer5h) }
    }

    private func commitBudget() {
        let budget = TokenUsageText.budget(budgetText) ?? 0
        model.updatePreferences { $0.tokenBudgetPer5h = budget }
        budgetText = Self.text(budget)
    }

    static func text(_ budget: Int) -> String { budget > 0 ? TokenUsageText.compact(budget) : "" }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.config.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}
