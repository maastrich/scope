import AppKit
import SwiftUI
import ScopeCore
import ScopeDrivers
import UserNotifications

/// Settings window (⌘,): General, Shell environment, Drivers, Automation.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShellSettingsView()
                .tabItem { Label("Shell Environment", systemImage: "terminal") }
            DriversSettingsView()
                .tabItem { Label("Drivers", systemImage: "cpu") }
            AutomationSettingsView()
                .tabItem { Label("Automation", systemImage: "terminal.fill") }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("Config folder") {
                    HStack(spacing: 8) {
                        Text(model.env.home.path)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal") { Reveal.inFinder(model.env.home) }
                            .controlSize(.small)
                    }
                }
                Picker("Default driver", selection: preference(\.defaultDriverID)) {
                    Text("Automatic").tag("")
                    Divider()
                    ForEach(model.drivers.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                Text(driverCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Editor") {
                EditorPicker()
            }
            Section("Terminal") {
                Stepper(value: terminalFontSize, in: Preferences.terminalFontSizeRange) {
                    LabeledContent("Font size", value: "\(model.config.preferences.terminalFontSize) pt")
                }
                Toggle("Use Option as the Meta key", isOn: preference(\.terminalOptionAsMeta))
                // One literal, not a `+` chain: only a literal is read as Markdown, so the code spans render.
                Text("""
                    Off, ⌥ types the character your layout puts there — `⌥(` and `⌥)` are how a French keyboard \
                    types braces. On, ⌥ sends ESC first, which shells read as Meta. Either way ⌥← ⌥→ ⌥⌫ ⌥⌦ still \
                    move and delete by word.
                    """)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Appearance", selection: preference(\.terminalAppearance)) {
                    Text("Follow system").tag(TerminalAppearanceMode.system)
                    Text("Always dark").tag(TerminalAppearanceMode.alwaysDark)
                }
                Picker("Cursor", selection: preference(\.terminalCursorStyle)) {
                    ForEach(TerminalCursorStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                Text(model.config.preferences.terminalCursorStyle.blinks
                     ? "Changes apply to every open thread. A blinking cursor fades in and out rather than switching on and off; a program may still ask for its own shape."
                     : "Changes apply to every open thread. A program may still ask for its own cursor shape.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                NotificationStatusRow()
            }
            Section("Confirmations") {
                Toggle("Ask before closing a running thread", isOn: preference(\.confirmCloseRunningThread))
                Toggle("Ask before quitting with running threads", isOn: preference(\.confirmQuitWithRunningThreads))
            }
            Section("Threads") {
                Toggle("Close exited threads automatically after 10 s", isOn: preference(\.autoCloseExitedThreads))
                Text("Off: an exited thread stays in the sidebar until you close it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("Relaunch running threads when Scope opens", isOn: preference(\.autoRelaunchThreads))
                Text("Threads that were running when Scope quit, updated or crashed start again, picking their driver session back up when they can. Hold ⇧ while Scope opens to skip it once.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Threads waiting for you") {
                Picker("Show the count", selection: preference(\.attentionCounter)) {
                    ForEach(AttentionCounterPlacement.allCases, id: \.self) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                Text("A waiting thread is always marked in place — a square dot, a bar down its row and the word “needs you”. This is only where the count of them goes; ⌥⌘↩ jumps to the next one either way.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Show waiting threads in the menu bar", isOn: preference(\.showMenuBarExtra))
            }
        }
        .formStyle(.grouped)
    }

    /// What the default actually decides: the driver a scope opens with, until you open one in it.
    private var driverCaption: String {
        let automatic = model.config.preferences.defaultDriverID.isEmpty
        let name = model.preferredProfile?.name ?? "the first driver"
        return automatic
            ? "Automatic picks the first agent profile installed (\(name) here). A scope then keeps the driver you last opened in it — ⌘T never asks twice."
            : "A scope keeps the driver you last opened in it; this is what a scope starts on."
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
        LabeledContent("Status") {
            HStack(spacing: 8) {
                Text(statusText)
                    .foregroundStyle(status == .denied ? AnyShapeStyle(Color("WarningText")) : AnyShapeStyle(.primary))
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .task { await refresh() }
        Text("Scope notifies you when a thread waits for input while the window is in the background.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
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

    private static let noneTag = "none"
    private static let customTag = "custom"

    var body: some View {
        Picker("Editor", selection: selection) {
            Text("None").tag(Self.noneTag)
            ForEach(installedEditors, id: \.rawValue) { editor in
                Text(displayName(editor)).tag(editor.rawValue)
            }
            Text("Custom command").tag(Self.customTag)
        }
        if selection.wrappedValue == Self.customTag {
            TextField("Command", text: $customCommand, prompt: Text("code -g {file}:{line}"))
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(commitCustomCommand)
            Text("Arguments separated by spaces. Placeholders: {path} (folder), {file}, {line}. The executable is resolved on your login-shell PATH.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        if let editor = model.config.preferences.editor {
            LabeledContent("Command") {
                Text(editor.argv.joined(separator: " "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var installedEditors: [KnownEditor] {
        KnownEditor.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
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
        Form {
            Section("Login shell") {
                LabeledContent("Shell") {
                    Text(ShellEnvironment.loginShell())
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                Picker("Probe", selection: probeMode) {
                    Text("Interactive login (-ilc)").tag(ShellProbeMode.interactiveLogin)
                    Text("Login (-lc)").tag(ShellProbeMode.login)
                    Text("None (path_helper only)").tag(ShellProbeMode.none)
                }
                Text("Scope runs your shell once at launch to capture PATH and the variables agents need. Change the mode if your PATH is only set in an interactive rc file, or if the probe is slow.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        if model.shellStatus == .probing {
                            ProgressView().controlSize(.small)
                        }
                        Text(statusText)
                    }
                }
                if let warning = resolved?.warning {
                    LabeledContent("Warning") {
                        Text(warning)
                            .foregroundStyle(Color("WarningText"))
                            .textSelection(.enabled)
                    }
                }
                Button("Re-probe now") {
                    model.reprobeShell()
                }
                .disabled(model.shellStatus == .probing)
            }
            Section("PATH") {
                if let resolved {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(resolved.path.split(separator: ":").enumerated()), id: \.offset) { _, entry in
                            Text(String(entry))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Not resolved yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
            Table(model.drivers.profiles) {
                TableColumn("Name") { profile in
                    HStack(spacing: 6) {
                        Image(systemName: profile.icon ?? "terminal")
                            .foregroundStyle(.secondary)
                        Text(profile.name)
                            .help("ID: \(profile.id)")
                        if profile.builtin == true {
                            Text("built-in")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                TableColumn("Command") { profile in
                    Text(([profile.command] + profile.args).joined(separator: " "))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Resolved") { profile in
                    resolvedText(for: profile)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .frame(minHeight: 180)

            if !model.drivers.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invalid profiles")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(Array(model.drivers.problems.enumerated()), id: \.offset) { _, problem in
                        Text("\(problem.file.lastPathComponent): \(problem.message)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .textSelection(.enabled)
                    }
                }
            }

            HStack {
                Button("Reveal in Finder") {
                    Reveal.inFinder(ScopeHome.driversURL(home: model.env.home))
                }
                Button("Reload") {
                    Task { await model.reloadDrivers() }
                }
                Spacer()
                Text("Profiles are JSON files in \(ScopeHome.driversURL(home: model.env.home).path). Edit them with any editor; Reload picks up changes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func resolvedText(for profile: DriverProfile) -> some View {
        switch model.shellStatus {
        case .probing:
            Text("…").foregroundStyle(.secondary)
        case .ready(let environment), .fallback(let environment):
            if let path = ExecutableResolver.resolve(profile.command, path: environment.path, shell: environment.shell) {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            } else {
                Text("not found")
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
    }
}
