import SwiftUI
import ScopeCore

/// The main window: sidebar / scene split view with the inspector attached to the scene, the whole window accepting
/// folder drops, and the model published to `ScopeCommands` through the focused scene value.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            // A plain HStack rather than `.inspector`: macOS splits the window toolbar at the inspector edge,
            // whereas the toolbar must span the full width with the inspector starting below it.
            HStack(spacing: 0) {
                SceneView()
                if inspectorPresented.wrappedValue {
                    Divider()
                    InspectorView()
                        .frame(width: model.inspectorTab == .delta ? 420 : 360)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .folderDropTarget { urls in
            Task { await model.addScopes(urls) }
        }
        .sheet(item: newTaskScope) { scope in
            NewTaskSheet(scope: scope)
                .environment(model)
        }
        .focusedSceneValue(\.appModel, model)
        .environment(model)
    }

    private var newTaskScope: Binding<ScopeState?> {
        Binding(
            get: { model.newTaskScopeID.flatMap { model.scope($0) } },
            set: { model.newTaskScopeID = $0?.id }
        )
    }

    /// The inspector is hidden in the empty state (no scope) whatever the persisted preference says.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { !model.scopes.isEmpty && model.inspectorShown },
            set: { model.inspectorShown = $0 }
        )
    }
}
