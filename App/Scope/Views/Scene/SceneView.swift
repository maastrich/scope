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
                        .id(model.config.preferences.chromeTheme)
                } else {
                    ScopeEmptyView(scope: scope)
                        .id(model.config.preferences.chromeTheme)
                }
            } else {
                SceneEmptyView()
                    .id(model.config.preferences.chromeTheme)
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let sent = model.messageUI.sent {
                    SentToast(notice: sent)
                        .transition(.opacity)
                        .padding(.bottom, model.exitNotices.isEmpty ? 12 : 0)
                }
                if !model.exitNotices.isEmpty {
                    ExitToastStack()
                }
            }
            .padding(.horizontal, 12)
            .animation(.easeOut(duration: 0.15), value: model.messageUI.sent?.id)
        }
        // The window's own title and subtitle, not a custom item: the system truncates them to the room left
        // and draws them bare (a custom `.principal` view overflowed on a long path).
        .navigationTitle(model.currentThread.map { ThreadTitle.path(scope: model.currentScope?.name, task: model.task(of: $0)?.name, thread: model.displayTitle(for: $0)) }
                         ?? model.contextDescription ?? BuildFlavor.displayName)
        .navigationSubtitle(model.currentThread.map(ThreadTitle.detail) ?? "")
        .toolbar { toolbar }
    }

    private func statePill(_ session: ThreadSession) -> some View {
        StatePill(state: session.displayState, pulses: session.isWorking,
                  detail: ThreadNotificationContent.failureDescription(session.lastFailure).map { "Failed: \($0)" })
            .help(ThreadTitle.currentDirectory(session))
            .accessibilityLabel("Thread state \(session.displayState.displayLabel), working directory \(ThreadTitle.currentDirectory(session))")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.toggleSidebar()
            } label: {
                Label("Sidebar", systemImage: "sidebar.left")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.icon)
            .help("Toggle Sidebar (⌃⌘S)")
            .accessibilityLabel("Toggle Sidebar")
        }
        .withoutSharedBackground()
        if let session = model.currentThread {
            // The state alone, centred. On macOS 26 the toolbar wraps a custom item in a 36 pt glass capsule,
            // which turned the 22 pt pill into a round blob taller than the title and out of line with the
            // trailing buttons; hiding the item's shared background leaves the pill its own quiet capsule.
            ToolbarItem(placement: .principal) { statePill(session) }
                .withoutSharedBackground()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.config.preferences.attentionCounter == .toolbar {
                AttentionToolbarButton()
            }
            TokenMeterToolbarButton()
            if let session = model.currentThread, session.deliversEvents {
                Button {
                    model.readReply(of: session)
                } label: {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 12))
                }
                .buttonStyle(.icon)
                .help("Read the agent's last reply (⇧⌘R)")
                .accessibilityLabel("Read Reply")
                .usageID("toolbar.read-reply", label: "Read reply (toolbar)")
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
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                .buttonStyle(.scopeGhost)
                .help("Open this checkout in your editor (⌘E, ⌥-click copies the path)")
            }
            ProblemPopover()
        }
        .withoutSharedBackground()
        // Its own item, declared last, so it stays anchored at the far right of the toolbar.
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.icon)
            .disabled(model.scopes.isEmpty)
            .help("Toggle Inspector (⌥⌘I)")
            .accessibilityLabel("Toggle Inspector")
        }
        .withoutSharedBackground()
    }
}

private extension ToolbarContent {
    /// Drops the glass capsule macOS 26 draws behind a toolbar item. The capsule is a material: it samples
    /// whatever scrolls under the toolbar, and nothing in this app is translucent. The item is left with no
    /// background at all rather than an opaque one painted over the glass, so every control in it brings its
    /// own button style.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
