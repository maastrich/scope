import AppKit
import SwiftUI
import ScopeCore

/// The centre column. Picks `SceneEmptyView` (no scope), `ScopeEmptyView` (scope or repo row without a thread),
/// `TaskEmptyView` (task without a thread) or the `ThreadPane` of the selected thread, and declares the scene
/// part of the window toolbar. Threads are switched from the sidebar alone; there is no tab strip.
struct SceneView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let scope = model.currentScope {
                if let session = model.currentThread {
                    ThreadPane(session: session)
                } else if let task = model.currentTask {
                    TaskEmptyView(task: task)
                } else {
                    ScopeEmptyView(scope: scope)
                }
            } else {
                SceneEmptyView()
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if !model.exitNotices.isEmpty {
                ExitToastStack()
                    .padding(.horizontal, 12)
            }
        }
        // The window's own title and subtitle, not a custom item: the system truncates them to the room left
        // and draws them bare (a custom `.principal` view overflowed on a long path and got a glass capsule
        // around the state pill's own on macOS 26).
        .navigationTitle(model.currentThread.map(ThreadTitle.title) ?? model.contextDescription ?? "Scope")
        .navigationSubtitle(model.currentThread.map { ThreadTitle.subtitle($0, scope: model.currentScope) } ?? "")
        .toolbar { toolbar }
    }

    /// macOS 26 gives every toolbar item a glass capsule of its own.
    private static var toolbarDrawsCapsules: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let session = model.currentThread {
            // The state alone, centred: on macOS 26 the toolbar's capsule is its background, so the pill draws none.
            ToolbarItem(placement: .principal) {
                StatePill(state: session.displayState, pulses: session.isWorking,
                          detail: ThreadNotificationContent.failureDescription(session.lastFailure).map { "Failed: \($0)" },
                          bare: Self.toolbarDrawsCapsules)
                    .help(ThreadTitle.currentDirectory(session))
                    .accessibilityLabel("Thread state \(session.displayState.displayLabel), working directory \(ThreadTitle.currentDirectory(session))")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.config.preferences.attentionCounter == .toolbar {
                AttentionToolbarButton()
            }
            if model.currentThread != nil || model.currentScope != nil {
                Button {
                    if NSEvent.modifierFlags.contains(.option), let path = model.currentEditorPath {
                        Pasteboard.copy(path)
                    } else {
                        model.openInEditor(thread: model.selectedThreadID)
                    }
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
                      ? "Choose an editor in Settings to enable this" : "Open in Editor (⌘E, ⌥-click copies the path)")
            }
            ProblemPopover()
        }
        // Its own item, declared last: a separate pill anchored at the far right of the toolbar.
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .disabled(model.scopes.isEmpty)
            .help("Toggle Inspector (⌥⌘I)")
            .accessibilityLabel("Toggle Inspector")
        }
    }
}
