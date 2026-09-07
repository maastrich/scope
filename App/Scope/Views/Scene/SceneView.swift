import SwiftUI
import ScopeCore

/// The centre column. Picks `SceneEmptyView` (no scope), `ScopeEmptyView` (scope without a thread) or the
/// tab strip + `ThreadPane` of the selected thread, and declares the scene part of the window toolbar.
struct SceneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let scope = model.currentScope {
                let threads = model.threads(in: scope.id)
                if !threads.isEmpty {
                    TabStrip(scope: scope, threads: threads)
                }
                if let session = model.currentThread {
                    ThreadPane(session: session)
                } else {
                    ScopeEmptyView(scope: scope)
                }
            } else {
                SceneEmptyView()
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if !model.exitNotices.isEmpty {
                ExitToastStack()
                    .padding(.horizontal, 12)
            }
        }
        .toolbar(removing: .title)
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let session = model.currentThread {
            ToolbarItem(placement: .navigation) {
                ThreadToolbar(session: session, scope: model.currentScope)
            }
        } else {
            ToolbarItem(placement: .principal) {
                Text("Scope")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.currentThread != nil || model.currentScope != nil {
                Button {
                    model.openInEditor(thread: model.selectedThreadID)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 12))
                        Text("Open in Editor")
                            .font(.system(size: 12, weight: .medium))
                        Text("⌘E")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(model.config.preferences.editor == nil)
                .help(model.config.preferences.editor == nil
                      ? "Choose an editor in Settings to enable this" : "Open in Editor (⌘E)")
            }
            ProblemPopover()
            Button {
                model.inspectorShown.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .disabled(model.scopes.isEmpty)
            .help("Toggle Inspector (⌥⌘I)")
        }
    }
}
