import SwiftUI
import ScopeGraph

/// Inline editor of a card: purpose, stack, setup and test. Save stores the card with manual
/// precedence (`edited = true`); Reset drops the flag and re-runs the quick analysis.
struct RepoCardEditor: View {
    @Environment(AppModel.self) private var model
    let entry: GraphCardEntry
    @State private var purpose = ""
    @State private var stack = ""
    @State private var setup = ""
    @State private var test = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.card.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Editing").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            field("Purpose") {
                TextField("One to three sentences", text: $purpose, axis: .vertical)
                    .lineLimit(2...5)
            }
            field("Stack") {
                TextField("node, typescript, react (comma separated)", text: $stack)
            }
            field("Setup") {
                TextField("pnpm install", text: $setup).font(.system(size: 11, design: .monospaced))
            }
            field("Test") {
                TextField("pnpm test", text: $test).font(.system(size: 11, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.graph.editingKey = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if entry.card.edited {
                    Button("Reset to Generated") { Task { await reset() } }
                        .help("Drops the manual edits and re-runs the quick analysis")
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .onAppear {
            purpose = entry.card.purpose ?? ""
            stack = entry.card.stack.joined(separator: ", ")
            setup = entry.card.setup ?? ""
            test = entry.card.test ?? ""
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() async {
        var card = entry.card
        card.purpose = trimmed(purpose)
        card.stack = stack.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        card.setup = trimmed(setup)
        card.test = trimmed(test)
        await model.graph.setManual(card, for: entry.key)
    }

    private func reset() async {
        await model.graph.resetToGenerated(entry.key)
        if let scope = model.currentScope {
            await model.analyzeGraph(scope: scope, withAI: false, force: true)
        }
    }

    private func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
