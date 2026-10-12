import SwiftUI
import ScopeGraph

/// Inline editor of a card: purpose, stack, setup, test and teardown. Save stores the card with manual
/// precedence (`edited = true`); Reset drops the flag and re-runs the quick analysis.
struct RepoCardEditor: View {
    @Environment(AppModel.self) private var model
    let entry: GraphCardEntry
    @State private var purpose = ""
    @State private var stack = ""
    @State private var setup = ""
    @State private var test = ""
    @State private var teardown = ""

    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.card.name).font(.scopeTitle)
                Spacer()
                Text("Editing").font(.scopeCaption).foregroundStyle(Ink.secondary)
            }
            field("Purpose", .purpose, grows: true) {
                TextField("One to three sentences", text: $purpose, axis: .vertical)
                    .lineLimit(2...5)
            }
            field("Stack", .stack) {
                TextField("node, typescript, react (comma separated)", text: $stack)
            }
            field("Setup", .setup) {
                TextField("pnpm install", text: $setup).font(.scopeValue)
            }
            field("Test", .test) {
                TextField("pnpm test", text: $test).font(.scopeValue)
            }
            field("Teardown", .teardown) {
                TextField("docker compose down (before a sandbox is removed)", text: $teardown)
                    .font(.scopeValue)
            }
            HStack(spacing: 8) {
                Button("Save") { Task { await save() } }
                    .buttonStyle(.scopePrimary)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.graph.editingKey = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if entry.card.edited {
                    Button("Reset to Generated") { Task { await reset() } }
                        .help("Drops the manual edits and re-runs the quick analysis")
                }
            }
            .buttonStyle(.scopeSecondary)
            .padding(.top, 2)
        }
        .textFieldStyle(.plain)
        .onAppear {
            purpose = entry.card.purpose ?? ""
            stack = entry.card.stack.joined(separator: ", ")
            setup = entry.card.setup ?? ""
            test = entry.card.test ?? ""
            teardown = entry.card.teardown ?? ""
        }
    }

    private enum Field { case purpose, stack, setup, test, teardown }

    /// `grows` is for the one field that wraps: a fixed-height box would clip its second line.
    @ViewBuilder
    private func field<Content: View>(_ label: String, _ id: Field, grows: Bool = false,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.scopeCaption).foregroundStyle(Ink.secondary)
            if grows {
                content().focused($focus, equals: id).scopeTextBox(focused: focus == id)
            } else {
                content().focused($focus, equals: id).scopeFieldBox(focused: focus == id, height: 22)
            }
        }
    }

    private func save() async {
        var card = entry.card
        card.purpose = trimmed(purpose)
        card.stack = stack.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        card.setup = trimmed(setup)
        card.test = trimmed(test)
        card.teardown = trimmed(teardown)
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
