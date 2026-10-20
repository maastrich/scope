import AppKit
import SwiftUI
import ScopeCore
import ScopeDrivers
import UserNotifications

/// Settings window (⌘,): General, Shell environment, Drivers, Automation, Assist.
struct SettingsView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        SettingsChrome(selection: $tab) {
            switch tab {
            case .general: GeneralSettingsView()
            case .shell: ShellSettingsView()
            case .drivers: DriversSettingsView()
            case .automation: AutomationSettingsView()
            case .assist: AssistSettingsView()
            }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var clearedUsage = false

    var body: some View {
        SettingsPage {
            SettingsSection("Configuration") {
                SettingsRow("Config folder") {
                    HStack(spacing: 8) {
                        Text(model.env.home.path)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal") { Reveal.inFinder(model.env.home) }
                            .buttonStyle(.scopeSecondary)
                    }
                }
                SettingsRow("Default driver") {
                    ScopePicker("Default driver", selection: preference(\.defaultDriverID), title: defaultDriverTitle) {
                        Text("Automatic").tag("")
                        Divider()
                        ForEach(model.drivers.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                }
                Text(driverCaption)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Editor") {
                EditorPicker()
            }
            SettingsSection("Appearance") {
                SettingsRow("Colours") {
                    ScopePicker("Colours", selection: preference(\.chromeTheme),
                                title: model.config.preferences.chromeTheme.title) {
                        ForEach(ChromeTheme.allCases, id: \.self) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                }
                Text("Brand is the Mobsuccess charter: ivory or onyx ground, white or navy cards. Neutral is white or near-black with grey chrome. The state colours and the terminal are the same in both.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show keyboard shortcuts while ⌘ is held", isOn: preference(\.showShortcutHints))
                    .toggleStyle(.scope)
                    .usageID("show-shortcut-hints", label: "Show keyboard shortcuts while ⌘ is held")
                Text("Hold ⌘ on its own for half a second: every button, row and tab with a shortcut shows it in a keycap beside itself. Let go and they disappear. The full list is Help ▸ Keyboard Shortcuts… (⌘/).")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Terminal") {
                SettingsRow("Font size") {
                    HStack(spacing: 8) {
                        Text("\(model.config.preferences.terminalFontSize) pt")
                            .foregroundStyle(Ink.primary)
                            .monospacedDigit()
                        ScopeStepper(value: model.config.preferences.terminalFontSize,
                                     range: Preferences.terminalFontSizeRange) { terminalFontSize.wrappedValue = $0 }
                    }
                }
                Toggle("Use Option as the Meta key", isOn: preference(\.terminalOptionAsMeta))
                    .toggleStyle(.scope)
                // One literal, not a `+` chain: only a literal is read as Markdown, so the code spans render.
                Text("""
                    Off, ⌥ types the character your layout puts there — `⌥(` and `⌥)` are how a French keyboard \
                    types braces. On, ⌥ sends ESC first, which shells read as Meta. Either way ⌥← ⌥→ ⌥⌫ ⌥⌦ still \
                    move and delete by word.
                    """)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Appearance") {
                    ScopePicker("Appearance", selection: preference(\.terminalAppearance),
                                title: model.config.preferences.terminalAppearance == .system ? "Follow system" : "Always dark") {
                        Text("Follow system").tag(TerminalAppearanceMode.system)
                        Text("Always dark").tag(TerminalAppearanceMode.alwaysDark)
                    }
                }
                Toggle("Claude Code follows the terminal palette", isOn: preference(\.claudeUsesTerminalPalette))
                    .toggleStyle(.scope)
                Text("Claude Code draws with the terminal's 16 colours, matched to the appearance, instead of its own theme. Applies to threads launched from now on.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Cursor") {
                    ScopePicker("Cursor", selection: preference(\.terminalCursorStyle),
                                title: model.config.preferences.terminalCursorStyle.title) {
                        ForEach(TerminalCursorStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                }
                Text(model.config.preferences.terminalCursorStyle.blinks
                     ? "Changes apply to every open thread. A blinking cursor fades in and out rather than switching on and off; a program may still ask for its own shape."
                     : "Changes apply to every open thread. A program may still ask for its own cursor shape.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
            }
            SettingsSection("Notifications") {
                NotificationStatusRow()
                Toggle("Show what the agent said", isOn: preference(\.notificationsQuoteAgent))
                    .toggleStyle(.scope)
                Text("A notification quotes the agent's question or the start of its answer. Off, it only says that the thread needs you or finished — worth it while sharing your screen.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Confirmations") {
                Toggle("Ask before closing a thread mid-turn or archiving a task with work in progress", isOn: preference(\.confirmCloseRunningThread))
                    .toggleStyle(.scope)
                Text("Only when something would be lost: an agent in the middle of a turn, uncommitted changes, an open pull request. A close or an archive can be taken back with ⌘Z either way.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Ask before quitting with running threads", isOn: preference(\.confirmQuitWithRunningThreads))
                    .toggleStyle(.scope)
            }
            SettingsSection("Threads") {
                Toggle("Close exited threads automatically after 10 s", isOn: preference(\.autoCloseExitedThreads))
                    .toggleStyle(.scope)
                Text("Off: an exited thread stays in the sidebar until you close it.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                Toggle("Relaunch running threads when Scope opens", isOn: preference(\.autoRelaunchThreads))
                    .toggleStyle(.scope)
                Text("Threads that were running when Scope quit, updated or crashed start again, picking their driver session back up when they can. Hold ⇧ while Scope opens to skip it once.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Ask agents to continue after a restart", isOn: preference(\.resumeInterruptedTurns))
                    .toggleStyle(.scope)
                    .disabled(!model.config.preferences.autoRelaunchThreads)
                    .usageID("resume-interrupted-turns", label: "Ask agents to continue after a restart")
                Text("A relaunched agent whose turn the restart cut short is told so once its prompt is back, and asked to continue from where its worktree stands. Shells are left alone, and so is a thread you type into first.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Orchestrator driver") {
                    ScopePicker("Orchestrator driver", selection: preference(\.orchestratorDriverID), title: orchestratorDriverTitle) {
                        Text("Automatic").tag("")
                        Divider()
                        ForEach(model.drivers.profiles.filter { $0.id != ResidentRole.terminalDriverID }) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                }
                Text("Every scope keeps an orchestrator and a terminal at its root. They start when the scope is first shown, start again if they die on their own, and can be stopped (⌘.) but not closed. A running orchestrator switches driver the next time it starts.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Tasks") {
                Toggle("Clean up after tasks automatically", isOn: preference(\.cleanUpAutomatically))
                    .toggleStyle(.scope)
                Text("When Scope opens, every 30 minutes and after each archive: sandbox folders no task owns, stale git worktrees, processes left by archived tasks, and saved changes older than 30 days. Archiving always stops a task's processes and saves its uncommitted changes.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Archive a task when its pull request merges", isOn: preference(\.archiveMergedTasks))
                    .toggleStyle(.scope)
                Text("Every open task's pull request is read from GitHub every 5 minutes. Once it is merged, the task is archived and a notice offers it back — but not while a thread of it is working or waiting, a task it launched is still open, it has uncommitted or unpushed changes, or a turn started after the merge. A task you restore after its merge stays open. A pull request closed without merging never archives anything.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("When main moves") {
                    ScopePicker("When main moves", selection: preference(\.followMain),
                                title: model.config.preferences.followMain.title) {
                        ForEach(FollowMainMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .usageID("follow-main", label: "When main moves")
                }
                Text("Every open task's branch is fetched and measured against the default branch with its pull request, and the lag shown in its Pull Request section and hover card. Ask the agent: when the branch conflicts with main, or GitHub says the pull request does, the task's thread is told what moved and asked to rebase, once per move of main. Rebase when clean: a branch behind without conflicts, with no thread at work, is rebased by Scope in its sandbox and pushed with lease when its pull request is open; one that conflicts is left as it was and the agent asked. Never: the lag is only shown. A task's context menu can hold its branch out of all of this. A scope may override the choice in config.json (followMain).")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Allow trying a task in my checkout", isOn: preference(\.allowTryInCheckout))
                    .toggleStyle(.scope)
                    .usageID("allow-try-in-checkout", label: "Allow trying a task in my checkout")
                Text("Off by default. On, a task's context menu offers Try in my checkout (and `scope task try` from your own terminal, never an agent's): your base checkout's uncommitted changes are stashed, HEAD is detached onto the task branch — your branch itself never moves — and a banner on the task and on Base offers Put back and Refresh. Put back switches back and applies the stash; it runs on its own when the task is archived or closed and when Scope quits, and finishes at the next launch if interrupted. A stash that conflicts is kept, never dropped. A scope may override the choice in config.json (allowTryInCheckout).")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Idle after") {
                    ScopePicker("Idle after", selection: preference(\.dormantAfterDays),
                                title: Self.idleTitle(model.config.preferences.dormantAfterDays)) {
                        ForEach(Self.idleChoices, id: \.self) { days in
                            Text(Self.idleTitle(days)).tag(days)
                        }
                    }
                }
                Text("A task with no thread activity for that long, or whose pull request was closed without merging, says so in its row and, arranged by state, goes under Dormant.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Sidebar") {
                SettingsRow("Rows") {
                    ScopePicker("Rows", selection: preference(\.sidebarRows),
                                title: model.config.preferences.sidebarRows.title) {
                        ForEach(SidebarRows.allCases, id: \.self) { rows in
                            Text(rows.title).tag(rows)
                        }
                    }
                }
                SettingsRow("Arrange") {
                    ScopePicker("Arrange", selection: preference(\.sidebarArrangement),
                                title: model.config.preferences.sidebarArrangement.title) {
                        ForEach(SidebarArrangement.allCases, id: \.self) { arrangement in
                            Text(arrangement.title).tag(arrangement)
                        }
                    }
                }
                SettingsRow("Finished threads") {
                    ScopePicker("Finished threads", selection: preference(\.finishedThreadLine),
                                title: model.config.preferences.finishedThreadLine.title) {
                        ForEach(FinishedThreadLine.allCases, id: \.self) { line in
                            Text(line.title).tag(line)
                        }
                    }
                }
                SettingsRow("Tiles kept") {
                    ScopePicker("Tiles kept", selection: preference(\.scopeTileOrder),
                                title: model.config.preferences.scopeTileOrder.title) {
                        ForEach(ScopeTileOrder.allCases, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                }
                Text("The tiles follow the swipe: the first is the next scope, the last the previous one. When they do not all fit, this picks which stay and which go behind the +N counter. The next and previous scopes always keep theirs. ⌃1…⌃9 always follow the declared order.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Swipe sideways on the sidebar to switch scope", isOn: preference(\.swipeBetweenScopes))
                    .toggleStyle(.scope)
                    .fixedSize(horizontal: false, vertical: true)
                if model.scopes.count > 1 {
                    SettingsRow("Scope order") {
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(Array(model.scopes.enumerated()), id: \.element.id) { index, scope in
                                HStack(spacing: 6) {
                                    Text(index < 9 ? "⌃\(index + 1)" : "")
                                        .font(.scopeCaption)
                                        .foregroundStyle(Ink.tertiary)
                                    Text(scope.name)
                                        .font(.scopeBody)
                                        .lineLimit(1)
                                    Button {
                                        model.moveScopes(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                                    } label: { Image(systemName: "chevron.up") }
                                        .buttonStyle(.icon)
                                        .disabled(index == 0)
                                        .accessibilityLabel("Move \(scope.name) earlier")
                                    Button {
                                        model.moveScopes(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                                    } label: { Image(systemName: "chevron.down") }
                                        .buttonStyle(.icon)
                                        .disabled(index == model.scopes.count - 1)
                                        .accessibilityLabel("Move \(scope.name) later")
                                }
                            }
                        }
                    }
                    Text("The declared order: what ⌃1…⌃9 and ⌥⌘←/→ follow. Dragging a tile onto another in the sidebar changes it too.")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Detailed rows add a line saying what each task or thread is doing (⌃⌘L). By state puts what needs you first, and rows move as their state changes; as a tree keeps loose threads, then tasks, in a fixed order (⌃⌘G).")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Git") {
                Toggle("Show commit, push and pull-request buttons", isOn: preference(\.showGitActions))
                    .toggleStyle(.scope)
                Text("Off: the Delta section is for reading what an agent did, and committing, pushing and opening a pull request stay its work in its thread. Pulling a base checkout, opening an existing pull request and asking a thread to fix conflicts are always there.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Threads opened by agents") {
                SettingsRow("Bring them to the front") {
                    ScopePicker("Bring them to the front", selection: preference(\.agentOpenedFocus),
                                title: model.config.preferences.agentOpenedFocus.title) {
                        ForEach(AgentOpenedFocus.allCases, id: \.self) { focus in
                            Text(focus.title).tag(focus)
                        }
                    }
                }
                Text("A thread or task an agent opens always appears in the sidebar with its state mark. This is whether it also replaces the terminal you are reading. What you open yourself always comes to the front.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Threads waiting for you") {
                SettingsRow("Show the count") {
                    ScopePicker("Show the count", selection: preference(\.attentionCounter),
                                title: model.config.preferences.attentionCounter.title) {
                        ForEach(AttentionCounterPlacement.allCases, id: \.self) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                }
                Text("A waiting thread is always marked in place — a square dot, a bar down its row and the word “needs you”. This is only where the count of them goes; ⌥⌘↩ jumps to the next one either way.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
            }
            TokenUsageSettingsSection()
            SettingsSection("Since your last visit") {
                Toggle("Say what moved when I come back to a scope", isOn: preference(\.showReturnDigest))
                    .toggleStyle(.scope)
                    .usageID("return-digest", label: "Say what moved when I come back")
                SettingsRow("Away for at least") {
                    ScopePicker("Away for at least", selection: preference(\.returnDigestAwayMinutes),
                                title: "\(model.config.preferences.returnDigestAwayMinutes) min") {
                        ForEach(Self.awayChoices(including: model.config.preferences.returnDigestAwayMinutes), id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .disabled(!model.config.preferences.showReturnDigest)
                }
                Text("Switching to a scope, or coming back to the app after this long, shows a line at the top of the sidebar: turns finished, questions, pull requests merged, checks failing. It goes at the first click or after ten seconds.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Menu bar") {
                Toggle("Show waiting threads in the menu bar", isOn: preference(\.showMenuBarExtra))
                    .toggleStyle(.scope)
            }
            QuickPanelSettingsSection()
            SettingsSection("Usage") {
                Toggle("Record how I use Scope (stays on this Mac)", isOn: preference(\.recordUsage))
                    .toggleStyle(.scope)
                    .usageID("record-usage", label: "Record how I use Scope")
                SettingsRow("History", caption: "Which buttons, commands and panels you use, by id, in \(model.env.home.appending(path: "usage").path) — never what you type, a path or a name. “scope usage” reads it back for you or an agent; nothing is sent anywhere. Kept 180 days.") {
                    Button(clearedUsage ? "Cleared" : "Clear History") {
                        Task {
                            await model.clearUsageHistory()
                            clearedUsage = true
                        }
                    }
                    .buttonStyle(.scopeSecondary)
                    .disabled(clearedUsage)
                    .usageID("clear-history", label: "Clear usage history")
                }
            }
        }
    }

    /// What the default actually decides: the driver a scope opens with, until you open one in it.
    /// The away delays offered, with a value set by hand in `config.json` kept in the list so the picker can show it.
    private static func awayChoices(including current: Int) -> [Int] {
        Array(Set([5, 10, 20, 30, 60, 120, current])).sorted()
    }

    private var driverCaption: String {
        let automatic = model.config.preferences.defaultDriverID.isEmpty
        let name = model.defaultProfile?.name ?? "the first driver"
        return automatic
            ? "Automatic picks the first agent profile installed (\(name) here) for everything agents, the CLI and schedules open. "
                + "Your own ⌘T keeps the driver you last opened in the scope."
            : "Every thread and task opened without naming a driver runs on it: yours (⌘T), an agent's, the CLI's, a schedule's."
    }

    private var orchestratorDriverTitle: String {
        let id = model.config.preferences.orchestratorDriverID
        return id.isEmpty ? "Automatic (\(model.residentProfile(for: .orchestrator)?.name ?? "none"))"
            : (model.drivers.profile(id: id)?.name ?? id)
    }

        private var defaultDriverTitle: String {
        let id = model.config.preferences.defaultDriverID
        return id.isEmpty ? "Automatic" : (model.drivers.profile(id: id)?.name ?? id)
    }

    private static let idleChoices = [1, 2, 3, 5, 7, 14, 0]

    private static func idleTitle(_ days: Int) -> String {
        days <= 0 ? "Never" : days == 1 ? "1 day" : "\(days) days"
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.config.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }

    private var terminalFontSize: Binding<Int> {
        Binding(
            get: { model.config.preferences.terminalFontSize },
            set: { size in model.updatePreferences { $0.terminalFontSize = Preferences.clampTerminalFontSize(size) } }
        )
    }
}

/// Read-only display of the notification authorization (`getNotificationSettings`, never a new request) with a
/// shortcut to the Notifications pane of System Settings.
private struct NotificationStatusRow: View {
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        SettingsRow("Status") {
            HStack(spacing: 8) {
                Text(statusText)
                    .foregroundStyle(status == .denied ? Color("WarningText") : Ink.primary)
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.scopeSecondary)
            }
        }
        .task { await refresh() }
        Text("Scope notifies you when a thread waits for input while the window is in the background.")
            .font(.scopeCaption)
            .foregroundStyle(Ink.secondary)
    }

    private var statusText: String {
        switch status {
        case nil: "Checking…"
        case .authorized: "Allowed"
        case .provisional: "Allowed quietly (provisional)"
        case .ephemeral: "Allowed for this session"
        case .denied: "Not allowed"
        case .notDetermined: "Not asked yet — the first waiting thread will ask"
        @unknown default: "Unknown"
        }
    }

    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
    }
}

/// Auto-detected editors (by bundle identifier) plus a free argv template.
private struct EditorPicker: View {
    @Environment(AppModel.self) private var model
    @State private var customCommand = ""
    @FocusState private var commandFocused: Bool

    private static let noneTag = "none"
    private static let customTag = "custom"

    var body: some View {
        SettingsRow("Editor") {
            ScopePicker("Editor", selection: selection, title: selectionTitle) {
                Text(automaticTitle).tag(Self.noneTag)
                ForEach(installedEditors, id: \.rawValue) { editor in
                    Text(editor.displayName).tag(editor.rawValue)
                }
                Text("Custom command").tag(Self.customTag)
            }
        }
        if selection.wrappedValue == Self.customTag {
            SettingsRow("Custom command") {
                TextField("Command", text: $customCommand, prompt: Text("code -g {file}:{line}"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($commandFocused)
                    .onSubmit(commitCustomCommand)
                    .scopeFieldBox(focused: commandFocused, height: 22)
                    .frame(width: 300)
            }
            Text("Arguments separated by spaces. Placeholders: {path} (folder), {file}, {line}. The executable is resolved on your login-shell PATH.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
        }
        if let editor = model.config.preferences.editor, let known = KnownEditor(template: editor) {
            Text("\(known.displayName) opens each checkout in a window of its own and comes back to it the next time; a file opens inside its checkout. A whole task shows every sandbox side by side.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
        }
    }

    /// In the order of `KnownEditor`, not of what is running: a menu that reshuffles is hard to read.
    private var installedEditors: [KnownEditor] {
        KnownEditor.allCases.filter(model.installedEditors.contains)
    }

    /// No editor chosen: the first "Open in Editor" picks one of the installed editors and saves it.
    private var automaticTitle: String {
        model.installedEditors.first.map { "Automatic (\($0.displayName))" } ?? "None"
    }

    private var selectionTitle: String {
        switch selection.wrappedValue {
        case Self.noneTag: automaticTitle
        case Self.customTag: "Custom command"
        case let tag: KnownEditor(rawValue: tag)?.displayName ?? tag
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                guard let editor = model.config.preferences.editor else { return Self.noneTag }
                if let known = KnownEditor(template: editor) { return known.rawValue }
                return Self.customTag
            },
            set: { tag in
                switch tag {
                case Self.noneTag:
                    model.updatePreferences { $0.editor = nil }
                case Self.customTag:
                    customCommand = model.config.preferences.editor?.argv.joined(separator: " ") ?? ""
                    commitCustomCommand()
                default:
                    if let known = KnownEditor(rawValue: tag) {
                        model.updatePreferences { $0.editor = known.template }
                    }
                }
            }
        )
    }

    private func commitCustomCommand() {
        let argv = customCommand.split(whereSeparator: \.isWhitespace).map(String.init)
        model.updatePreferences { $0.editor = argv.isEmpty ? nil : EditorTemplate(argv: argv) }
    }
}

// MARK: - Shell environment

private struct ShellSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage {
            SettingsSection("Login shell") {
                SettingsRow("Shell") {
                    Text(ShellEnvironment.loginShell())
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                SettingsRow("Probe") {
                    ScopePicker("Probe", selection: probeMode, title: probeTitle(probeMode.wrappedValue)) {
                        ForEach([ShellProbeMode.interactiveLogin, .login, .none], id: \.self) { mode in
                            Text(probeTitle(mode)).tag(mode)
                        }
                    }
                }
                Text("Scope runs your shell once at launch to capture PATH and the variables agents need. Change the mode if your PATH is only set in an interactive rc file, or if the probe is slow.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
            }
            SettingsSection("Status") {
                SettingsRow("State") {
                    HStack(spacing: 6) {
                        if model.shellStatus == .probing {
                            ScopeSpinner(size: 12)
                        }
                        Text(statusText)
                            .foregroundStyle(Ink.primary)
                    }
                }
                if let warning = resolved?.warning {
                    SettingsRow("Warning") {
                        Text(warning)
                            .foregroundStyle(Color("WarningText"))
                            .textSelection(.enabled)
                    }
                }
                Button("Re-probe now") {
                    model.reprobeShell()
                }
                .buttonStyle(.scopeSecondary)
                .disabled(model.shellStatus == .probing)
                .padding(.top, 8)
            }
            SettingsSection("PATH") {
                if let resolved {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(resolved.path.split(separator: ":").enumerated()), id: \.offset) { _, entry in
                            Text(String(entry))
                                .font(.scopeValue)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Not resolved yet.")
                        .foregroundStyle(Ink.secondary)
                }
            }
        }
    }

    private var resolved: ResolvedShellEnvironment? {
        switch model.shellStatus {
        case .probing: nil
        case .ready(let environment), .fallback(let environment): environment
        }
    }

    private var statusText: String {
        switch model.shellStatus {
        case .probing: "Probing…"
        case .ready(let environment): "Ready — from \(environment.source.rawValue)"
        case .fallback(let environment): "Fallback — from \(environment.source.rawValue)"
        }
    }

    private func probeTitle(_ mode: ShellProbeMode) -> String {
        switch mode {
        case .interactiveLogin: "Interactive login (-ilc)"
        case .login: "Login (-lc)"
        case .none: "None (path_helper only)"
        }
    }

    private var probeMode: Binding<ShellProbeMode> {
        Binding(
            get: { model.config.preferences.shellProbe },
            set: { mode in model.updatePreferences { $0.shellProbe = mode } }
        )
    }
}

// MARK: - Drivers

private struct DriversSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Our rows, not a `Table`: its header and its column separators are AppKit's, and three read-only
            // columns have no use for sorting or resizing.
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        SectionLabel(text: "Name")
                        SectionLabel(text: "Command")
                        SectionLabel(text: "Resolved")
                    }
                    ForEach(model.drivers.profiles) { profile in
                        Rectangle().fill(Surface.stroke).frame(height: 1)
                            .gridCellColumns(3)
                        GridRow {
                            HStack(spacing: 6) {
                                Image(systemName: profile.icon ?? "terminal")
                                    .foregroundStyle(Ink.secondary)
                                    .frame(width: 16)
                                Text(profile.name)
                                    .foregroundStyle(Ink.primary)
                                    .lineLimit(1)
                                    .help("ID: \(profile.id)")
                                if profile.builtin == true {
                                    Chip(text: "built-in")
                                }
                            }
                            Text(([profile.command] + profile.args).joined(separator: " "))
                                .font(.scopeValue)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            resolvedText(for: profile)
                        }
                        .font(.scopeBody)
                        .frame(height: 28)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180)

            let withModel = model.drivers.profiles.filter(\.acceptsModel)
            if !withModel.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Default model")
                    ForEach(withModel) { profile in
                        HStack(spacing: 8) {
                            Text(profile.name)
                                .font(.scopeBody)
                                .foregroundStyle(Ink.secondary)
                                .frame(width: 150, alignment: .leading)
                            DriverModelField(profile: profile)
                        }
                    }
                    Text("What a thread of this driver runs on when neither the request nor the scope names a model "
                         + "(a scope's own default is in its settings sheet). Empty leaves the driver to its own default.")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.drivers.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invalid profiles")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(Array(model.drivers.problems.enumerated()), id: \.offset) { _, problem in
                        Text("\(problem.file.lastPathComponent): \(problem.message)")
                            .font(.scopeValue)
                            .foregroundStyle(PullRequestStyle.failing)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                Button("Reveal in Finder") {
                    Reveal.inFinder(ScopeHome.driversURL(home: model.env.home))
                }
                .buttonStyle(.scopeSecondary)
                Button("Reload") {
                    Task { await model.reloadDrivers() }
                }
                .buttonStyle(.scopeSecondary)
                Spacer()
                Text("Profiles are JSON files in \(ScopeHome.driversURL(home: model.env.home).path). Edit them with any editor; Reload picks up changes.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Surface.ground)
    }

    /// One driver's default model: typed freely, with the profile's known models as a menu beside the field, and
    /// saved on ↩ or when the field loses focus.
    private struct DriverModelField: View {
        @Environment(AppModel.self) private var model
        let profile: DriverProfile
        @State private var text = ""
        @FocusState private var focused: Bool

        var body: some View {
            HStack(spacing: 6) {
                TextField("Model", text: $text, prompt: Text("driver's own"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit(commit)
                    .scopeFieldBox(focused: focused, height: 22)
                    .frame(width: 220)
                    .usageID("driver-model-\(profile.id)", label: "Default model of \(profile.name)")
                if !profile.knownModels.isEmpty {
                    Menu {
                        Button("Driver's own") { text = ""; commit() }
                        Divider()
                        ForEach(profile.knownModels, id: \.self) { name in
                            Button(name) { text = name; commit() }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .usageID("driver-model-pick-\(profile.id)", label: "Pick the default model of \(profile.name)")
                }
            }
            .onAppear { text = model.config.preferences.driverModels[profile.id] ?? "" }
            .onChange(of: focused) { _, now in if !now { commit() } }
        }

        private func commit() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (model.config.preferences.driverModels[profile.id] ?? "") != trimmed else { return }
            model.updatePreferences { $0.driverModels[profile.id] = trimmed.isEmpty ? nil : trimmed }
        }
    }

    @ViewBuilder
    private func resolvedText(for profile: DriverProfile) -> some View {
        switch model.shellStatus {
        case .probing:
            Text("…").foregroundStyle(Ink.secondary)
        case .ready(let environment), .fallback(let environment):
            if let path = ExecutableResolver.resolve(profile.command, path: environment.path, shell: environment.shell) {
                Text(path)
                    .font(.scopeValue)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            } else {
                Text("not found")
                    .foregroundStyle(PullRequestStyle.failing)
            }
        }
    }
}
