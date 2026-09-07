import SwiftUI
import ScopeCore

/// The main window: sidebar / scene split view with the inspector attached, the whole window accepting
/// folder drops, and the model published to `ScopeCommands` through the focused scene value.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            SceneView()
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspectorPresented) {
            InspectorView()
                .inspectorColumnWidth(min: 320, ideal: model.inspectorTab == .delta ? 420 : 360, max: 520)
        }
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
