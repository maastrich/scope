import AppKit
import SwiftUI
import ScopeCore

/// The main window: sidebar / scene split view with the inspector attached to the scene, the whole window accepting
/// folder drops, and the model published to `ScopeCommands` through the focused scene value.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The sidebar as it was before ⌘M, put back when the thread is restored.
    @State private var columnsBeforeMaximize: NavigationSplitViewVisibility?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 400)
        } detail: {
            // A plain HStack rather than `.inspector`: macOS gives the inspector its own toolbar section (the
            // toolbar splits at the inspector edge and the trailing items move above the inspector), whereas the
            // toolbar must span the full width with the inspector starting below it. The divider is a drag handle
            // (320…520 pt, persisted in `UIStateStore`).
            HStack(spacing: 0) {
                SceneView()
                if inspectorPresented.wrappedValue {
                    InspectorResizeHandle(width: inspectorWidth)
                    InspectorView()
                        .frame(width: model.inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        // ⌘M: the sidebar goes with the inspector, and comes back as it was.
        .onChange(of: model.threadMaximized) { _, maximized in
            if maximized {
                columnsBeforeMaximize = columns
                columns = .detailOnly
            } else if let saved = columnsBeforeMaximize {
                columnsBeforeMaximize = nil
                columns = saved
            }
        }
        // Bringing the sidebar back by hand (its toolbar button) ends the maximized thread.
        .onChange(of: columns) { _, visibility in
            guard model.threadMaximized, visibility != .detailOnly else { return }
            columnsBeforeMaximize = nil
            model.restoreLayout()
        }
        // Nothing left to maximize: a window without sidebar and without thread would be a dead end.
        .onChange(of: model.currentThread?.id) { _, id in
            if id == nil { model.restoreLayout() }
        }
        .overlay {
            if model.paletteShown {
                CommandPalette()
            }
        }
        .folderDropTarget { urls in
            Task { await model.addScopes(urls) }
        }
        .sheet(item: newTaskScope) { scope in
            // The resolved driver, never the raw preference: "" means automatic, and an empty picker would
            // leave the sheet without a driver to ask for a proposal.
            NewTaskSheet(scope: scope, defaultDriverID: model.preferredDriverID ?? "")
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

    private var inspectorWidth: Binding<Double> {
        Binding(
            get: { model.inspectorWidth },
            set: { model.inspectorWidth = min(max($0, UIState.inspectorWidthRange.lowerBound), UIState.inspectorWidthRange.upperBound) }
        )
    }

    /// The inspector is hidden in the empty state (no scope) and while a thread is maximized, whatever the
    /// persisted preference says.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { !model.scopes.isEmpty && model.inspectorShown && !model.threadMaximized },
            set: { model.inspectorShown = $0 }
        )
    }
}

/// The divider between the scene and the inspector, draggable over an 9 pt hit area with the resize cursor.
private struct InspectorResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .cursor(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = width }
                                width = (startWidth ?? width) - value.translation.width
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .accessibilityLabel("Inspector width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width += 20
                case .decrement: width -= 20
                @unknown default: break
                }
            }
    }
}
