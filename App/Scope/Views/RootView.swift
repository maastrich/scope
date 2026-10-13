import AppKit
import SwiftUI
import ScopeCore

/// The main window: sidebar, scene and inspector as three flat columns of one surface, separated by hairlines,
/// under a toolbar that spans them all; the whole window accepts folder drops, and the model is published to
/// `ScopeCommands` through the focused scene value.
///
/// Plain columns rather than `NavigationSplitView` and `.inspector`: on macOS 26 the split view draws its sidebar
/// as a rounded panel floating over the window, and gives the inspector its own toolbar section. Both dividers
/// are drag handles (widths persisted in `UIStateStore`).
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        // Before any child is built: the tokens read it as they are drawn.
        let theme = model.config.preferences.chromeTheme
        let _ = (ChromePalette.theme = theme)
        HStack(spacing: 0) {
            if sidebarPresented {
                SidebarView()
                    .frame(width: model.sidebarWidth)
                    .transition(.move(edge: .leading))
                ColumnResizeHandle(width: sidebarWidth, growsWithDrag: true, label: "Sidebar width")
            }
            SceneView()
            if inspectorPresented.wrappedValue {
                ColumnResizeHandle(width: inspectorWidth, growsWithDrag: false, label: "Inspector width")
                InspectorView()
                    .frame(width: model.inspectorWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Surface.ground)
        .toolbarBackground(Surface.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .id(theme)
        // Nothing left to maximize: a window without sidebar and without thread would be a dead end.
        .onChange(of: model.currentThread?.id) { _, id in
            if id == nil { model.restoreLayout() }
        }
        .overlay {
            if model.paletteShown {
                CommandPalette()
            }
        }
        .sheet(item: $model.globalSheet) { sheet in
            GlobalSheetView(sheet: sheet)
                .environment(model)
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

    private var sidebarWidth: Binding<Double> {
        Binding(
            get: { model.sidebarWidth },
            set: { model.sidebarWidth = min(max($0, UIState.sidebarWidthRange.lowerBound), UIState.sidebarWidthRange.upperBound) }
        )
    }

    /// ⌘M hides the sidebar with the inspector; ⌃⌘S hides it on its own.
    private var sidebarPresented: Bool {
        model.sidebarShown && !model.threadMaximized
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

/// A hairline between two columns, draggable over a 9 pt hit area with the resize cursor. `growsWithDrag` says
/// which side the column is on: dragging right widens the sidebar and narrows the inspector.
private struct ColumnResizeHandle: View {
    @Binding var width: Double
    var growsWithDrag: Bool
    var label: String
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Surface.stroke)
            .frame(width: 1)
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
                                width = (startWidth ?? width) + (growsWithDrag ? value.translation.width : -value.translation.width)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
            .accessibilityLabel(label)
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
