import AppKit
import SwiftUI
import ScopeCore
import UniformTypeIdentifiers

/// The sidebar header: the current scope as a tile and its name, then the other scopes as tiles — as many as fit,
/// the rest behind a `+N` counter. A tile is one click to its scope, back where the user was in it; its corner
/// mark says what is happening there. The name is still a menu (every declared scope, "Declare a Scope… ⌘O",
/// "Remove Scope…"), and right-click keeps the scope actions, plus what the tile shows (icon, colour, logo).
struct ScopeSwitcher: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    /// Called by the "Rename…" menu item; the sidebar owns the rename dialog.
    var onRename: @MainActor (ScopeState) -> Void

    @State private var iconBeingEdited = false
    @State private var iconText = ""

    var body: some View {
        let others = model.scopeTiles(besides: scope)
        // As many neighbour tiles as fit beside the scope's whole name; the rest go behind the +N counter. Only
        // when no tile is left and the name still does not fit beside the counter does the name truncate.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: others.count, through: 0, by: -1)), id: \.self) { visible in
                row(others: others, visible: visible, truncatesName: false)
            }
            row(others: others, visible: 0, truncatesName: true)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { contextMenu }
        .alert("Tile of \(scope.name)", isPresented: $iconBeingEdited) {
            TextField("An emoji, or a letter or two", text: $iconText)
            Button("Set") {
                let icon = iconText.trimmingCharacters(in: .whitespacesAndNewlines)
                model.updateScopeIdentity(scope.id) { $0.icon = icon.isEmpty ? nil : icon }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown on the tile in place of the first letter of the name. Leave it empty to go back to the letter.")
        }
    }

    private func row(others: [ScopeState], visible: Int, truncatesName: Bool) -> some View {
        let hidden = Array(others.dropFirst(visible))
        return HStack(spacing: 7) {
            Menu {
                switcherMenu
            } label: {
                HStack(spacing: 7) {
                    ScopeTile(scope: scope)
                    Text(scope.name)
                        .font(.scopeTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(scope.kind == .missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: !truncatesName, vertical: false)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: !truncatesName, vertical: true)
            .help("\(scope.name) — \(caption) — \(scope.url.path)")
            .accessibilityLabel("Scope: \(scope.name). Switch scope")

            if scope.discovery == .scanning {
                ScopeSpinner(size: 10)
            }
            // The repo count moved to the tooltip and to the Repositories header; only a state worth a word
            // (scanning, a failed scan, a missing folder) still takes room here.
            if captionIsStatus {
                Text(caption)
                    .font(.scopeCaption)
                    .foregroundStyle(captionIsError ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 2)

            ForEach(others.prefix(visible)) { other in
                Button {
                    model.selectScope(other.id)
                } label: {
                    ScopeTile(scope: other, activity: model.activity(of: other))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Dragging a tile onto another moves its scope there in the declared order — the order of ⌃1…⌃9,
                // and of the tiles themselves when Settings arranges them that way.
                .draggable(other.id.rawValue)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, model.scope(ScopeID(rawValue: raw)) != nil else { return false }
                    model.moveScope(ScopeID(rawValue: raw), onto: other.id)
                    return true
                }
                .help(tileHelp(other))
                .accessibilityLabel("\(other.name), \(model.activity(of: other).label)")
            }
            if !hidden.isEmpty {
                moreMenu(hidden)
            }
        }
    }

    /// The scopes that did not fit, behind a counter that carries the most pressing mark among them.
    private func moreMenu(_ hidden: [ScopeState]) -> some View {
        let urgent = hidden.map(model.activity(of:)).min() ?? .quiet
        return Menu {
            ForEach(hidden) { other in
                Button(scopeMenuTitle(other)) { model.selectScope(other.id) }
            }
        } label: {
            Text("+\(hidden.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 5)
                .frame(height: 20)
                .background(Fill.quiet, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if urgent != .quiet, urgent != .missing {
                        ScopeActivityMark(activity: urgent).offset(x: 3, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(hidden.count) more \(hidden.count == 1 ? "scope" : "scopes")")
        .accessibilityLabel("\(hidden.count) more scopes, \(urgent.label)")
    }

    /// `@acme — a thread needs you — 12 repos (⌃2)`: the number is the scope's declared position, which is what
    /// ⌃1…⌃9 follow whatever order the tiles are in.
    private func tileHelp(_ other: ScopeState) -> String {
        let count = other.repos.count
        var text = "\(other.name) — \(model.activity(of: other).label) — \(count) \(count == 1 ? "repo" : "repos")"
        if let index = model.scopes.firstIndex(where: { $0.id == other.id }), index < 9 { text += " (⌃\(index + 1))" }
        return text
    }

    private var captionIsStatus: Bool {
        captionIsError || scope.discovery == .scanning
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

    /// `@acme — a thread needs you`, `notes — 3 repos`: the state when there is one to tell, else the size.
    private func scopeMenuTitle(_ other: ScopeState) -> String {
        let activity = model.activity(of: other)
        if activity != .quiet, other.id != scope.id { return "\(other.name) — \(activity.label)" }
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
            model.presentGraph()
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
        Menu("Tile") {
            Button("Set Icon…") {
                iconText = scope.declaration.icon ?? ""
                iconBeingEdited = true
            }
            Menu("Colour") {
                Button {
                    model.updateScopeIdentity(scope.id) { $0.tint = nil }
                } label: {
                    if scope.declaration.tint == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
                }
                Divider()
                ForEach(ScopeTint.allCases, id: \.self) { tint in
                    Button {
                        model.updateScopeIdentity(scope.id) { $0.tint = tint }
                    } label: {
                        if scope.declaration.tint == tint { Label(tint.title, systemImage: "checkmark") } else { Text(tint.title) }
                    }
                }
            }
            Divider()
            Button("Choose Logo…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.image]
                panel.allowsMultipleSelection = false
                panel.prompt = "Use as Logo"
                panel.message = "Choose an image for the tile of \(scope.name). Scope keeps its own copy."
                if panel.runModal() == .OK, let url = panel.url { model.setScopeLogo(scope.id, from: url) }
            }
            if scope.declaration.logo != nil {
                Button("Remove Logo") { model.removeScopeLogo(scope.id) }
            }
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
