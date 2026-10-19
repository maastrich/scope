import SwiftUI
import SwiftTerm
import ScopeCore

/// Menu bar and every keyboard shortcut (spec §7, blueprint §(e).5). Actions reach the focused window's
/// `AppModel` through `@FocusedValue(\.appModel)`; items are disabled when no window is focused.
///
/// ⌘-combinations are menu key equivalents and win over the terminal; nothing an agent TUI needs uses ⌘.
/// ⌘K opens the command palette, so "clear" is ⌥⌘K. ⌘R is Refresh Scope (platform meaning), Relaunch is
/// ⌥⌘R; ⌘W closes the thread, ⇧⌘W the window; ⌘M maximizes the thread, so Minimize is ⌥⌘M. The full table is
/// Help ▸ Keyboard Shortcuts… (`ShortcutCatalog`), and ⌘ held alone shows each control's chord beside it
/// (`CommandKeyHints`, which reads them back off this menu).
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
                    model.presentGraph()
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
            // Left enabled on the scope's orchestrator and terminal: `close` refuses them with a beep, which is surer than
            // a disabled item whose ⌘W might fall through to the terminal.
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
                if let model {
                    DriverMenuItems { driver, chosen in
                        Task { await model.newThreadInCurrentContext(driverID: driver, model: chosen) }
                    }
                    .environment(model)
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
                Button("Close Task") {
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

            Button("Read Reply") {
                model?.readCurrentReply()
            }
            // ⌘R is Refresh Scope, ⌥⌘R Relaunch, ⌃⌘R Show Repositories.
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(currentThread == nil && model?.currentTask == nil)

            // Relaunch already resumes when it can; this is the way out of that.
            Button("Start Fresh Session") {
                if let model, let id = model.selectedThreadID {
                    Task { await model.startFresh(id) }
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

            // Mail's chord for read / unread.
            Button("Mark as Read") {
                if let model, let id = model.selectedThreadID { model.markRead(id) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(currentThread.map { $0.displayState.acknowledged == $0.displayState } ?? true)

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
            .disabled(model?.currentTask == nil)

            Divider()

            Button("Command Palette…") {
                model?.showPalette(mode: .all)
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(model == nil)

            Button("Ask Orchestrator…") {
                model?.showAskOrchestrator()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model?.currentOrchestrator == nil)

            // The floating panel the system-wide chord opens (Settings › General › Anywhere); here so it can be found.
            Button("Quick Panel…") {
                AppServices.model?.showQuickPanel()
            }

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

            // ⌃ rather than ⌘: ⌘1…9 are the threads of the scope, as tabs are in a browser.
            Menu("Scope") {
                ForEach(1...9, id: \.self) { number in
                    Button(scopeMenuTitle(number)) {
                        model?.selectScope(index: number - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .control)
                    .disabled(number > (model?.scopes.count ?? 0))
                }
            }
            Button("Next Scope") { model?.selectAdjacentScope(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((model?.scopes.count ?? 0) < 2)
            Button("Previous Scope") { model?.selectAdjacentScope(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((model?.scopes.count ?? 0) < 2)

            Divider()

            Button("Delta") { model?.showInspector(.delta) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model == nil)
            Button("Pull Request") { model?.showInspector(.pullRequest) }
                .disabled(model == nil)
            Button("Base") { model?.showInspector(.base) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(model == nil)

            Divider()

            Button("Inbox…") { model?.showInbox() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Pull Requests…") { model?.showPullRequests() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model?.currentScope == nil)
            Button("Graph…") { model?.presentGraph() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(model?.currentScope == nil)

            Divider()

            // Plain-key shortcuts of the Delta section (they need the list or the diff focused); listed here to be found.
            Menu("Delta") {
                Button("Next File (j)") { model?.delta.selectNextFile(1); model?.inspector.show(.diff) }
                Button("Previous File (k)") { model?.delta.selectNextFile(-1); model?.inspector.show(.diff) }
                Divider()
                Button("Next Hunk (])") { model?.delta.focusHunk(1) }
                Button("Previous Hunk ([)") { model?.delta.focusHunk(-1) }
            }
            .disabled(model?.currentTask == nil)
        }
    }

    /// `@acme`, or `Scope 4` for a slot no scope fills.
    private func scopeMenuTitle(_ number: Int) -> String {
        guard let scopes = model?.scopes, scopes.indices.contains(number - 1) else { return "Scope \(number)" }
        return scopes[number - 1].name
    }

    // MARK: View

    private var viewMenu: some Commands {
        CommandGroup(after: .sidebar) {
            // The sidebar is the app's own column, not a split-view item, so the system's Show Sidebar does not
            // reach it.
            Button(model?.sidebarShown == false ? "Show Sidebar" : "Hide Sidebar") {
                model?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(model == nil)

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

            Button(model?.config.preferences.sidebarRows == .compact ? "Detailed Rows" : "Compact Rows") {
                model?.updatePreferences { $0.sidebarRows = $0.sidebarRows == .detailed ? .compact : .detailed }
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(model == nil)

            Button(model?.config.preferences.sidebarArrangement == .byState ? "Arrange as a Tree" : "Arrange by State") {
                model?.updatePreferences { $0.sidebarArrangement = $0.sidebarArrangement == .tree ? .byState : .tree }
            }
            .keyboardShortcut("g", modifiers: [.command, .control])
            .disabled(model == nil)

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
        model?.selection != nil
    }


}
