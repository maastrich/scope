import SwiftUI
import ScopeControl
import ScopeCore

/// Settings ▸ General ▸ Token usage: the toolbar meter, an optional budget of the user's own, the API-equivalent cost.
struct TokenUsageSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var budgetText = ""
    @FocusState private var budgetFocused: Bool

    var body: some View {
        SettingsSection("Token usage") {
            Toggle("Show the token meter in the toolbar", isOn: preference(\.showTokenMeter))
                .toggleStyle(.scope)
                .usageID("show-token-meter", label: "Show the token meter in the toolbar")
            SettingsRow("Budget per 5 h", caption: "Optional. Turns the meter into a gauge against your own figure, e.g. 20M.") {
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
            Text("Counted from the transcripts of Claude Code threads, subagents and cache reads included. Scope cannot see your plan’s limit, so the meter shows what was consumed, never what is left. The cost is what the same tokens would cost at API list prices, not what a subscription bills.")
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
