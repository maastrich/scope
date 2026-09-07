import AppKit
import SwiftUI
import ScopeCore

/// The sidebar header: the current scope's name as a switcher. The menu lists every declared scope (repo count,
/// checkmark on the current one), "Declare a Scope… ⌘O" and "Remove Scope…"; the caption shows the scan state.
/// Right-click keeps the scope actions (Refresh, Analyze Graph, Discovery Depth, Rename…, Reveal, Remove).
struct ScopeSwitcher: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    /// Called by the "Rename…" menu item; the sidebar owns the rename dialog.
    var onRename: @MainActor (ScopeState) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                switcherMenu
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: scope.kind == .missing ? "folder.badge.questionmark" : "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(scope.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(scope.kind == .missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("Switch scope — \(scope.url.path)")
            .accessibilityLabel("Scope: \(scope.name). Switch scope")

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
                .help(scope.url.path)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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

    // MARK: Switcher menu

    @ViewBuilder
    private var switcherMenu: some View {
        ForEach(model.scopes) { other in
            Button {
                model.selectScope(other.id)
            } label: {
                if other.id == scope.id {
                    Label(scopeMenuTitle(other), systemImage: "checkmark")
                } else {
                    Text(scopeMenuTitle(other))
                }
            }
        }
        Divider()
        Button("Declare a Scope…") {
            Task {
                let urls = await FolderPicker.chooseFolders()
                guard !urls.isEmpty else { return }
                await model.addScopes(urls)
            }
        }
        .keyboardShortcut("o", modifiers: .command)
        Button("Remove Scope…", role: .destructive) {
            Task { await ScopeActions.remove(scope, model: model) }
        }
    }

    private func scopeMenuTitle(_ other: ScopeState) -> String {
        let count = other.repos.count
        switch other.kind {
        case .missing: return "\(other.name) — missing"
        case .repo: return "\(other.name) — repo"
        default: return "\(other.name) — \(count) \(count == 1 ? "repo" : "repos")"
        }
    }

    // MARK: Context menu

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

/// Shared scope actions used by the sidebar header and by the menu bar.
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
