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
                Text("None").tag(Self.noneTag)
                ForEach(installedEditors, id: \.rawValue) { editor in
                    Text(displayName(editor)).tag(editor.rawValue)
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
        if let editor = model.config.preferences.editor {
            SettingsRow("Command") {
                Text(editor.argv.joined(separator: " "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ink.secondary)
            }
        }
    }

    private var installedEditors: [KnownEditor] {
        KnownEditor.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    private var selectionTitle: String {
        switch selection.wrappedValue {
        case Self.noneTag: "None"
        case Self.customTag: "Custom command"
        case let tag: KnownEditor(rawValue: tag).map(displayName) ?? tag
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                guard let editor = model.config.preferences.editor else { return Self.noneTag }
                if let known = KnownEditor.allCases.first(where: { $0.template == editor }) {
                    return known.rawValue
                }
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

    private func displayName(_ editor: KnownEditor) -> String {
        switch editor {
        case .cursor: "Cursor"
        case .vscode: "Visual Studio Code"
        case .zed: "Zed"
        case .sublime: "Sublime Text"
        case .jetbrains: "JetBrains IDE"
        case .nova: "Nova"
        }
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
