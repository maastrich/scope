import SwiftUI

/// Right-hand inspector: a segmented Graph / Delta / Base control in its toolbar and, for M0, placeholders
/// in place of the three panels. ⌘D / ⌘⇧B already switch tabs so the muscle memory exists from day one.
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.inspectorTab {
            case .graph:
                ContentUnavailableView {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(graphDescription)
                }
            case .delta:
                ContentUnavailableView {
                    Label("Delta", systemImage: "plus.forwardslash.minus")
                } description: {
                    Text("Delta arrives with tasks in M2: uncommitted changes, the task branch against its base, and commit / push / PR from here.")
                }
            case .base:
                ContentUnavailableView {
                    Label("Base", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Base arrives in M3: browse a repo's base checkout read-only and open a secondary shell in it.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .toolbar {
            // `.inspector` keeps this view alive while collapsed, so its toolbar items would otherwise
            // leak into the window toolbar; only declare them while the inspector is actually visible.
            if inspectorVisible {
                ToolbarItem(placement: .principal) {
                    Picker("Inspector tab", selection: $model.inspectorTab) {
                        ForEach(InspectorTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue.capitalized).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
        }
    }

    /// Mirrors `RootView.inspectorPresented`: hidden in the empty state whatever the preference says.
    private var inspectorVisible: Bool {
        !model.scopes.isEmpty && model.inspectorShown
    }

    private var graphDescription: String {
        guard let scope = model.currentScope else {
            return "Graph arrives in M3: one card per repo with purpose, stack and entry points."
        }
        let repos = scope.repos.count
        let remotes = scope.repos.filter { $0.facts?.remote != nil }.count
        return "\(scope.name) · \(repos) \(repos == 1 ? "repo" : "repos") · \(remotes) \(remotes == 1 ? "remote" : "remotes")\n\nGraph arrives in M3: one card per repo with purpose, stack and entry points."
    }
}
