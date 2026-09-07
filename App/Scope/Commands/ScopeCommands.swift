import SwiftUI
import SwiftTerm
import ScopeCore

/// Menu bar and every keyboard shortcut (spec §7, blueprint §(e).5). Actions reach the focused window's
/// `AppModel` through `@FocusedValue(\.appModel)`; items are disabled when no window is focused.
///
/// ⌘-combinations are menu key equivalents and win over the terminal; nothing an agent TUI needs uses ⌘.
/// ⌘K is reserved for the command palette (M4), so "clear" is ⌥⌘K.
struct ScopeCommands: Commands {
    @FocusedValue(\.appModel) private var model

    /// Links shown in the Help menu.
    private static let repositoryURL = URL(string: "https://github.com/maastrich/scope")

    var body: some Commands {
        fileMenu
        threadMenu
        goMenu
        viewMenu
        helpMenu
    }

    // MARK: File

    private var fileMenu: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Scope…") {
                Task {
                    let urls = await FolderPicker.chooseFolders()
                    guard !urls.isEmpty else { return }
                    await model?.addScopes(urls)
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Refresh Scope") {
                if let model, let scope = model.currentScope {
                    model.refreshScope(scope.id)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(model?.currentScope == nil)

            Button("Remove Scope…") {
                if let model, let scope = model.currentScope {
                    Task { await ScopeActions.remove(scope, model: model) }
                }
            }
            .disabled(model?.currentScope == nil)

            Divider()

            Button("Close Thread") {
                if let model, let id = model.selectedThreadID {
                    Task { _ = await model.close(id, force: false) }
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model?.selectedThreadID == nil)
        }
    }

    // MARK: Thread

    private var threadMenu: some Commands {
        CommandMenu("Thread") {
            Button("New Thread") {
                if let model, let scope = model.currentScope {
                    Task { _ = await model.newThread(in: scope.id) }
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model?.currentScope == nil)

            Menu("New Thread With Driver") {
                ForEach(model?.drivers.profiles ?? []) { profile in
                    Button(profile.name) {
                        if let model, let scope = model.currentScope {
                            Task { _ = await model.newThread(in: scope.id, driverID: profile.id) }
                        }
                    }
                }
            }
            .disabled(model?.currentScope == nil)

            Button("New Task…") {}
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(true)
                .help("Tasks arrive in M2")

            Divider()

            Button("Relaunch") {
                if let model, let id = model.selectedThreadID {
                    Task { await model.relaunch(id) }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(currentThread == nil || currentThread?.isAlive == true)

            Button("Resume") {
                if let model, let id = model.selectedThreadID {
                    Task { await model.resume(id) }
                }
            }
            .disabled(currentThread == nil || currentThread?.isAlive == true || currentThread?.canResume != true)

            Button("Stop") {
                if let model, let id = model.selectedThreadID {
                    model.stop(id)
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(currentThread?.isAlive != true)

            Button("Rename…") {}
                .disabled(true)
                .help("Thread renaming arrives with tasks in M2")

            Divider()

            Button("Next Thread") {
                model?.selectNextThread()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(threadCount < 2)

            Button("Previous Thread") {
                model?.selectPreviousThread()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(threadCount < 2)

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("Thread \(number)") {
                    model?.selectThread(index: number - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                .disabled(number > threadCount)
            }
        }
    }

    // MARK: Go

    private var goMenu: some Commands {
        CommandMenu("Go") {
            Button("Open in Editor") {
                model?.openInEditor(thread: model?.selectedThreadID)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!canOpenInEditor)

            Button("Open Task in Editor") {}
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(true)
                .help("Tasks arrive in M2")

            Divider()

            Button("Command Palette…") {}
                .keyboardShortcut("k", modifiers: .command)
                .disabled(true)
                .help("The command palette arrives in M4")

            Divider()

            Button("Graph") { show(.graph) }
                .disabled(model == nil)
            Button("Delta") { show(.delta) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model == nil)
            Button("Base") { show(.base) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
    }

    // MARK: View

    private var viewMenu: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") {
                model?.inspectorShown.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model == nil)

            Button("Clear Scrollback") {
                currentThread?.terminalView.clearScrollback()
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(currentThread == nil)
        }
    }

    // MARK: Help

    private var helpMenu: some Commands {
        CommandGroup(replacing: .help) {
            if let url = Self.repositoryURL {
                Link("Scope on GitHub", destination: url)
            }
            Button("Open Config Folder") {
                if let home = model?.env.home {
                    Reveal.withDefaultApp(home)
                }
            }
            .disabled(model == nil)
        }
    }

    // MARK: Helpers

    private var currentThread: ThreadSession? {
        model?.currentThread
    }

    private var threadCount: Int {
        guard let model, let scope = model.currentScope else { return 0 }
        return model.threads(in: scope.id).count
    }

    private var canOpenInEditor: Bool {
        guard let model, model.config.preferences.editor != nil else { return false }
        return model.selection != nil
    }

    private func show(_ tab: InspectorTab) {
        model?.inspectorTab = tab
        model?.inspectorShown = true
    }
}
