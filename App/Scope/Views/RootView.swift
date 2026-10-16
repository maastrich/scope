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
    /// The window's width, for the viewer column's share of what the sidebar and the inspector leave.
    @State private var windowWidth: Double = 0

    var body: some View {
        @Bindable var model = model
        // The chrome is rebuilt when the colours change (Settings ▸ Appearance): the tokens are plain values read
        // while a view is drawn, so nothing else would tell the sidebar and the inspector to draw again. The scene
        // is left alone — rebuilding it would take the terminal off screen — and handles its own empty views.
        let theme = model.config.preferences.chromeTheme
        HStack(spacing: 0) {
            if sidebarPresented {
                SidebarView()
                    .usageArea("sidebar")
                    .id(theme)
                    .frame(width: model.sidebarWidth)
                    .transition(.move(edge: .leading))
                ColumnResizeHandle(width: sidebarWidth, growsWithDrag: true, defaultWidth: ColumnLayout.defaultSidebarWidth, label: "Sidebar width")
            }
            SceneView()
                .usageArea("thread")
            // The diff or base file opened from the inspector reads beside it, the height of the window, rather than
            // under its sections (`InspectorViewerColumn`). An answer is read beside the terminal with or without
            // the inspector: it is about the thread, not about the task's lists.
            if viewerPresented {
                ColumnResizeHandle(width: viewerWidth, growsWithDrag: false, defaultWidth: defaultViewerWidth, label: "Viewer width")
                InspectorViewerColumn()
                    .usageSurface("viewer", label: "Reading column")
                    .id(theme)
                    .frame(width: viewerWidth.wrappedValue)
                    .transition(.move(edge: .trailing))
            }
            if inspectorPresented.wrappedValue {
                ColumnResizeHandle(width: inspectorWidth, growsWithDrag: false, defaultWidth: ColumnLayout.defaultInspectorWidth, label: "Inspector width")
                InspectorView()
                    .usageSurface("inspector", label: "Inspector")
                    .id(theme)
                    .frame(width: model.inspectorWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { windowWidth = $0 }
        .background(Surface.ground)
        .toolbarBackground(Surface.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // Nothing left to maximize: a window without sidebar and without thread would be a dead end.
        .onChange(of: model.currentThread?.id) { _, id in
            if id == nil { model.restoreLayout() }
        }
        .overlay {
            if model.paletteShown {
                CommandPalette()
                    .usageSurface("palette", label: "Command palette")
            }
        }
        .sheet(item: $model.globalSheet) { sheet in
            GlobalSheetView(sheet: sheet)
                .usageSurface(sheet.usageSurface.id, label: sheet.usageSurface.label)
                .environment(model)
        }
        .sheet(item: newTaskScope) { scope in
            // The resolved driver, never the raw preference: "" means automatic, and an empty picker would
            // leave the sheet without a driver to ask for a proposal.
            NewTaskSheet(scope: scope, defaultDriverID: model.preferredDriverID ?? "")
                .usageSurface("sheet.new-task", label: "New Task")
                .environment(model)
        }
        .sheet(item: scopeSettings, onDismiss: {
            guard model.graphFollowsScopeSettings else { return }
            model.graphFollowsScopeSettings = false
            model.presentGraph()
        }) { scope in
            ScopeSettingsSheet(scope: scope)
                .usageSurface("sheet.scope-settings", label: "Scope settings")
                .environment(model)
        }
        .focusedSceneValue(\.appModel, model)
        .environment(model)
    }

    private var scopeSettings: Binding<ScopeState?> {
        Binding(
            get: { model.scopeSettingsID.flatMap { model.scope($0) } },
            set: { model.scopeSettingsID = $0?.id }
        )
    }

    private var newTaskScope: Binding<ScopeState?> {
        Binding(
            get: { model.newTaskScopeID.flatMap { model.scope($0) } },
            set: { model.newTaskScopeID = $0?.id }
        )
    }

    /// The viewer column shows with the inspector, or alone for an answer being read — never over a maximized thread.
    private var viewerPresented: Bool {
        guard let viewer = model.shownViewer, !model.threadMaximized else { return false }
        return inspectorPresented.wrappedValue || viewer == .reading
    }

    private var inspectorWidth: Binding<Double> {
        Binding(
            get: { model.inspectorWidth },
            set: { model.inspectorWidth = ColumnLayout.clampInspectorWidth($0) }
        )
    }

    /// The viewer column in points, read from and written to its share of the width the terminal and it divide.
    private var viewerWidth: Binding<Double> {
        let shared = viewerSharedWidth
        return Binding(
            get: { (model.inspector.viewerShare * shared).rounded() },
            set: { model.inspector.viewerShare = ColumnLayout.clampViewerShare($0 / shared) }
        )
    }

    /// Half of what the terminal and the viewer divide: what a double-click on their sash goes back to.
    private var defaultViewerWidth: Double {
        (ColumnLayout.defaultViewerShare * viewerSharedWidth).rounded()
    }

    /// The width the terminal and the viewer divide: the window less the other columns and their hairlines.
    private var viewerSharedWidth: Double {
        max(1, windowWidth
            - (sidebarPresented ? model.sidebarWidth + 1 : 0)
            - (inspectorPresented.wrappedValue ? model.inspectorWidth + 1 : 0) - 1)
    }

    private var sidebarWidth: Binding<Double> {
        Binding(
            get: { model.sidebarWidth },
            set: { model.sidebarWidth = ColumnLayout.clampSidebarWidth($0) }
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

/// A column boundary: `Sash` over the width it moves. `growsWithDrag` says which side the column is on — dragging
/// right widens the sidebar and narrows the inspector — and a double-click goes back to `defaultWidth`.
private struct ColumnResizeHandle: View {
    @Binding var width: Double
    var growsWithDrag: Bool
    var defaultWidth: Double
    var label: String
    @State private var startWidth: Double?

    var body: some View {
        Sash(axis: .vertical,
             began: { startWidth = width },
             moved: { delta in width = (startWidth ?? width) + (growsWithDrag ? delta : -delta) },
             ended: { startWidth = nil },
             reset: { width = defaultWidth })
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
