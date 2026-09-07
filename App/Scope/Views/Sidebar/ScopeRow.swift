import AppKit
import SwiftUI
import ScopeCore

/// Sidebar row for a scope: chevron, folder icon, name (semibold), caption (`3 repos` / `repo` / `scanning…` /
/// `missing` / `scan failed`), context menu.
struct ScopeRow: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    /// Called by the "Rename…" menu item; the sidebar owns the rename dialog.
    var onRename: @MainActor (ScopeState) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button {
                scope.isExpanded.toggle()
            } label: {
                Image(systemName: scope.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help(scope.isExpanded ? "Collapse" : "Expand")
            .accessibilityLabel(scope.isExpanded ? "Collapse \(scope.name)" : "Expand \(scope.name)")

            Image(systemName: scope.kind == .missing ? "folder.badge.questionmark" : "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(scope.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .foregroundStyle(scope.kind == .missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

            Spacer(minLength: 4)

            if scope.discovery == .scanning {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(captionIsError ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 64, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(scope.url.path)
        .contextMenu { contextMenu }
    }

    private var caption: String {
        if case .failed = scope.discovery { return "scan failed" }
        if scope.discovery == .scanning { return "scanning…" }
        switch scope.kind {
        case .missing: return "missing"
        case .repo: return "repo"
        case .multiRepo: return "\(scope.repos.count) repos"
        case .plain: return "no repos"
        }
    }

    private var captionIsError: Bool {
        if case .failed = scope.discovery { return true }
        return scope.kind == .missing
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("New Thread Here") {
            Task { _ = await model.newThread(in: scope.id) }
        }
        .keyboardShortcut("t", modifiers: .command)
        Menu("New Thread With Driver") {
            ForEach(model.drivers.profiles) { profile in
                Button(profile.name) {
                    Task { _ = await model.newThread(in: scope.id, driverID: profile.id) }
                }
            }
        }
        Divider()
        Button("Refresh") {
            model.refreshScope(scope.id)
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        Button("Analyze Graph") {
            model.inspectorTab = .graph
            model.inspectorShown = true
            Task { await model.analyzeGraph(scope: scope, withAI: false) }
        }
        .disabled(scope.repos.isEmpty || model.graph.isGenerating)
        Menu("Discovery Depth") {
            ForEach(0...3, id: \.self) { depth in
                Button {
                    model.setDiscoveryDepth(depth, for: scope.id)
                } label: {
                    if depth == scope.declaration.discoveryDepth {
                        Label(depthLabel(depth), systemImage: "checkmark")
                    } else {
                        Text(depthLabel(depth))
                    }
                }
            }
        }
        Button("Rename…") {
            onRename(scope)
        }
        Divider()
        Button("Reveal in Finder") {
            Reveal.inFinder(scope.url)
        }
        Button("Copy Path") {
            Pasteboard.copyPath(scope.url)
        }
        Divider()
        Button("Remove Scope…", role: .destructive) {
            Task { await ScopeActions.remove(scope, model: model) }
        }
    }

    private func depthLabel(_ depth: Int) -> String {
        switch depth {
        case 0: "0 — the folder itself"
        case 1: "1 — direct children"
        default: "\(depth) levels"
        }
    }
}

/// Shared scope actions used by the sidebar context menu and by the menu bar.
@MainActor
enum ScopeActions {
    /// Confirms with a sheet ("Remove *acme* from Scope? Nothing is deleted on disk.") and removes the scope.
    /// Running threads are hung up. Sandboxes are never deleted from here (tasks own them), so the alert has no
    /// accessory.
    static func remove(_ scope: ScopeState, model: AppModel) async {
        let running = model.threads(in: scope.id).filter(\.isAlive).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(scope.name)” from Scope?"
        var informative = "Nothing is deleted on disk."
        if running > 0 {
            informative += "\n\n\(running) running \(running == 1 ? "thread" : "threads") will be hung up."
        }
        alert.informativeText = informative
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return }
        await model.removeScope(scope.id, closingThreads: true)
    }
}
