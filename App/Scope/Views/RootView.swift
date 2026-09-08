import AppKit
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
        .overlay {
            if model.paletteShown {
                CommandPalette()
            }
        }
        .folderDropTarget { urls in
            Task { await model.addScopes(urls) }
        }
        .sheet(item: newTaskScope) { scope in
            NewTaskSheet(scope: scope, defaultDriverID: model.config.preferences.defaultDriverID)
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

    /// The inspector is hidden in the empty state (no scope) whatever the persisted preference says.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { !model.scopes.isEmpty && model.inspectorShown },
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
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
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
