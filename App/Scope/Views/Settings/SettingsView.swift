import AppKit
import SwiftUI
import ScopeCore
import ScopeDrivers
import UserNotifications

/// Settings window (⌘,): General, Shell environment, Drivers, Automation.
struct SettingsView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        SettingsChrome(selection: $tab) {
            switch tab {
            case .general: GeneralSettingsView()
            case .shell: ShellSettingsView()
            case .drivers: DriversSettingsView()
            case .automation: AutomationSettingsView()
            }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

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
            }
            SettingsSection("Confirmations") {
                Toggle("Ask before closing a running thread", isOn: preference(\.confirmCloseRunningThread))
                    .toggleStyle(.scope)
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
            }
            SettingsSection("Tasks") {
                Toggle("Clean up after tasks automatically", isOn: preference(\.cleanUpAutomatically))
                    .toggleStyle(.scope)
                Text("When Scope opens, every 30 minutes and after each archive: sandbox folders no task owns, stale git worktrees, processes left by archived tasks, and saved changes older than 30 days. Archiving always stops a task's processes and saves its uncommitted changes.")
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
            SettingsSection("Menu bar") {
                Toggle("Show waiting threads in the menu bar", isOn: preference(\.showMenuBarExtra))
                    .toggleStyle(.scope)
            }
        }
    }

    /// What the default actually decides: the driver a scope opens with, until you open one in it.
    private var driverCaption: String {
        let automatic = model.config.preferences.defaultDriverID.isEmpty
        let name = model.preferredProfile?.name ?? "the first driver"
        return automatic
            ? "Automatic picks the first agent profile installed (\(name) here). A scope then keeps the driver you last opened in it — ⌘T never asks twice."
            : "A scope keeps the driver you last opened in it; this is what a scope starts on."
    }

    private var defaultDriverTitle: String {
        let id = model.config.preferences.defaultDriverID
        return id.isEmpty ? "Automatic" : (model.drivers.profile(id: id)?.name ?? id)
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
