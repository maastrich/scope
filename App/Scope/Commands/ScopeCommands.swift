import SwiftUI
import SwiftTerm
import ScopeCore

/// Menu bar and every keyboard shortcut (spec §7, blueprint §(e).5). Actions reach the focused window's
/// `AppModel` through `@FocusedValue(\.appModel)`; items are disabled when no window is focused.
///
/// ⌘-combinations are menu key equivalents and win over the terminal; nothing an agent TUI needs uses ⌘.
/// ⌘K opens the command palette, so "clear" is ⌥⌘K. ⌘R is Refresh Scope (platform meaning), Relaunch is
/// ⌥⌘R; ⌘W closes the thread, ⇧⌘W the window; ⌘M maximizes the thread, so Minimize is ⌥⌘M. The full table is
/// Help ▸ Keyboard Shortcuts… (`ShortcutCatalog`).
struct ScopeCommands: Commands {
    @FocusedValue(\.appModel) private var model

    /// Sparkle updater owned by `ScopeApp`; backs "Check for Updates…" in the application menu.
    let updater: UpdaterController

    /// Links shown in the Help menu.
    private static let repositoryURL = URL(string: "https://github.com/maastrich/scope")

    init(updater: UpdaterController) {
        self.updater = updater
        MainActor.assumeIsolated { CommandServices.updater = updater }
    }

    var body: some Commands {
        appMenu
        fileMenu
        editMenu
        threadMenu
        goMenu
        viewMenu
        windowMenu
        helpMenu
    }

    // MARK: Scope (application menu)

    private var appMenu: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
    }

    // MARK: File

    private var fileMenu: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Declare a Scope…") {
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
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model?.currentScope == nil)

            Button("Analyze Graph") {
                if let model, let scope = model.currentScope {
                    model.inspectorTab = .graph
                    model.inspectorShown = true
                    Task { await model.analyzeGraph(scope: scope, withAI: false) }
                }
            }
            .disabled(model?.currentScope == nil || model?.currentScope?.repos.isEmpty != false || model?.graph.isGenerating == true)

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

            Button("Undo Close Thread") {
                model?.undoCloseThread()
            }
            .keyboardShortcut(canUndoClose ? KeyboardShortcut("t", modifiers: [.command, .shift]) : nil)
            .disabled(!canUndoClose)

            Button("Close Window") {
                CommandServices.closeKeyWindow()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }

    // MARK: Edit (terminal find)

    /// SwiftTerm's find bar: the actions reach the terminal view only while it is first responder
    /// (the focused thread pane); anywhere else they are no-ops.
    private var editMenu: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { CommandServices.textFinder(.showFindInterface) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { CommandServices.textFinder(.nextMatch) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { CommandServices.textFinder(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { CommandServices.textFinder(.setSearchString) }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }

    // MARK: Thread

    private var threadMenu: some Commands {
        CommandMenu("Thread") {
            Button("New Thread") {
                if let model { Task { await model.newThreadInCurrentContext() } }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model?.currentScope == nil)
            .help("New Thread \(model?.newThreadTargetDescription ?? "")".trimmingCharacters(in: .whitespaces))

            Menu("New Thread With Driver") {
                ForEach(model?.drivers.profiles ?? []) { profile in
                    Button(profile.name) {
                        if let model { Task { await model.newThreadInCurrentContext(driverID: profile.id) } }
                    }
                }
            }
            .disabled(model?.currentScope == nil)

            Button("New Task…") {
                model?.presentNewTask()
            }
            // ⇧⌘T belongs to Undo Close Thread while a close can be undone (Safari-style).
            .keyboardShortcut(canUndoClose ? nil : KeyboardShortcut("t", modifiers: [.command, .shift]))
            .disabled(model?.currentScope == nil || model?.currentScope?.kind == .missing)

            Menu("Task") {
                Button("Archive Task") {
                    if let model, let task = model.currentTask { Task { await model.archiveTask(task.id) } }
                }
                .disabled(model?.currentTask == nil)
                Button("Close Task…") {
                    if let model, let task = model.currentTask { Task { await model.closeTask(task.id, deleteBranch: false) } }
                }
                .disabled(model?.currentTask == nil)
                Button("Reveal Task in Finder") {
                    if let task = model?.currentTask { Reveal.inFinder(task.record.rootURL) }
                }
                .disabled(model?.currentTask == nil)
            }

            Divider()

            Button("Relaunch") {
                if let model, let id = model.selectedThreadID {
                    Task { await model.relaunch(id) }
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
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

            Button("Rename Thread…") {
                if let model, let id = model.selectedThreadID { model.promptRenameThread(id) }
            }
            .disabled(model?.selectedThreadID == nil)

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

            Button("Next Thread Waiting for You") {
                model?.revealNextWaitingThread()
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled((model?.waitingThreads.count ?? 0) == 0)

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

            Button("Open Task in Editor") {
                if let model, let task = model.currentTask { model.openTaskInEditor(task) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model?.currentTask == nil || model?.config.preferences.editor == nil)

            Divider()

            Button("Command Palette…") {
                model?.showPalette(mode: .all)
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model == nil)

            Button("Go to File…") {
                model?.showPalette(mode: .files)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model == nil)

            // Xcode's "Open Quickly" chord, for muscle memory.
            Button("Go to File (Open Quickly)…") {
                model?.showPalette(mode: .files)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Filter Sidebar") {
                model?.focusSidebarFilter()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(model == nil)

            Divider()

            Button("Graph") { show(.graph) }
                .disabled(model == nil)
            Button("Delta") { show(.delta) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model == nil)
            Button("Base") { show(.base) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Pull Requests") { show(.pullRequests) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model == nil)

            Divider()

            // Plain-key shortcuts of the Delta panel (they need the panel focused); listed here to be found.
            Menu("Delta") {
                Button("Next File (j)") { model?.delta.selectNextFile(1) }
                Button("Previous File (k)") { model?.delta.selectNextFile(-1) }
                Divider()
                Button("Next Hunk (])") { model?.delta.focusHunk(1) }
                Button("Previous Hunk ([)") { model?.delta.focusHunk(-1) }
            }
            .disabled(model?.currentTask == nil)
        }
    }

    // MARK: View

    private var viewMenu: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model?.threadMaximized == true ? "Restore Thread" : "Maximize Thread") {
                model?.toggleThreadMaximized()
            }
            .keyboardShortcut("m", modifiers: .command)
            .disabled(model?.threadMaximized != true && currentThread == nil)

            Button("Toggle Inspector") {
                model?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model == nil)

            Button(model?.currentScope?.reposShown == true ? "Hide Repositories" : "Show Repositories") {
                model?.toggleRepositories()
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
            .disabled(model?.currentScope == nil)

            Button("Clear Scrollback") {
                currentThread?.terminalView.clearScrollback()
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
            .disabled(currentThread == nil)
        }
    }

    // MARK: Window

    /// ⌘M belongs to Maximize Thread, so Minimize moves to ⌥⌘M — the chord macOS already gives Minimize All.
    /// The group is replaced rather than added to: two items claiming ⌘M would leave AppKit to pick one.
    private var windowMenu: some Commands {
        CommandGroup(replacing: .windowSize) {
            Button("Minimize") { CommandServices.miniaturizeKeyWindow() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Zoom") { CommandServices.zoomKeyWindow() }
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

            Divider()

            Button("Keyboard Shortcuts…") {
                ShortcutsWindow.show()
            }
            .keyboardShortcut("/", modifiers: .command)
        }
    }

    // MARK: Helpers

    private var currentThread: ThreadSession? {
        model?.currentThread
    }

    private var canUndoClose: Bool {
        model?.canUndoCloseThread == true
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
