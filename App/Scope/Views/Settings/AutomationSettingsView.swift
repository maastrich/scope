import AppKit
import ScopeControl
import ScopeCore
import ScopeDrivers
import SwiftUI

/// Settings ▸ Automation: what agents may ask Scope to do, and the `scope` command line tool.
///
/// The two live together on purpose. The command line and the MCP server are the same door, and this pane
/// is where the user decides how far it opens.
struct AutomationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installMessage: String?
    @State private var installFailure: String?
    @State private var mcpStates: [MCPRegistration.Client: MCPRegistration.State] = [:]
    @State private var claudePath: String?
    @State private var mcpBusy = false
    @State private var mcpFailure: String?
    @State private var skillStates: [SkillInstaller.Client: SkillInstaller.State] = [:]
    @State private var skillFailure: String?
    /// The scope whose schedules the Schedules section shows; the current one at first.
    @State private var scheduleScope: ScopeID?

    var body: some View {
        SettingsPage {
            SettingsSection("Command line") {
                SettingsRow("Inside a thread") {
                    Text("`scope` is already on the PATH")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                }
                SettingsRow("Your own terminal") {
                    HStack(spacing: 8) {
                        Text(linkState)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(isInstalled ? "Reinstall" : "Install") { install() }
                            .buttonStyle(.scopeSecondary)
                            .disabled(toolPath == nil)
                    }
                }
                if let installFailure {
                    Text(installFailure)
                        .font(.scopeCaption)
                        .foregroundStyle(PullRequestStyle.failing)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let installMessage {
                    Text(installMessage)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // One literal, not a `+` chain: only a literal is read as Markdown, so the code spans render.
                Text("""
                    `scope list`, `scope thread new`, `scope task new`. `scope mcp` speaks MCP on stdio, so an \
                    agent can drive Scope with the same commands.
                    """)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("MCP server") {
                Text("""
                    Registers `scope mcp` with the agents you run outside Scope too, so any of their sessions can \
                    list, open threads and create tasks. They count as agents: the rules below apply to them.
                    """)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(MCPRegistration.Client.allCases) { client in
                    SettingsRow(client.title) {
                        HStack(spacing: 8) {
                            Text(mcpCaption(mcpStates[client]))
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.secondary)
                            if let title = mcpActionTitle(mcpStates[client]) {
                                Button(title) { toggleMCP(client) }
                                    .buttonStyle(.scopeSecondary)
                                    .disabled(mcpBusy || toolPath == nil)
                            }
                        }
                    }
                }
                if let mcpFailure {
                    Text(mcpFailure)
                        .font(.scopeCaption)
                        .foregroundStyle(PullRequestStyle.failing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .task { await refreshMCP() }

            SettingsSection("Skills") {
                Text("""
                    Installs the **Scope** skill for your user, so every session of these agents knows how to \
                    put work in a task, open threads in it and close it — by name or slug, through `scope` or the \
                    MCP tools. One folder per agent, next to your other skills.
                    """)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(SkillInstaller.Client.allCases) { client in
                    SettingsRow(client.title) {
                        HStack(spacing: 8) {
                            Text(skillCaption(skillStates[client]))
                                .font(.system(size: 12))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let title = skillActionTitle(skillStates[client]) {
                                Button(title) { toggleSkill(client) }
                                    .buttonStyle(.scopeSecondary)
                            }
                        }
                    }
                }
                if let skillFailure {
                    Text(skillFailure)
                        .font(.scopeCaption)
                        .foregroundStyle(PullRequestStyle.failing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Reveal Skill Text") {
                    Reveal.inFinder(skillInstaller.skillFile(.claudeCode).deletingLastPathComponent())
                }
                .buttonStyle(.scopeSecondary)
                .disabled(skillStates[.claudeCode] != .installed && skillStates[.claudeCode] != .outdated)
                .padding(.top, 8)
            }
            .task { refreshSkills() }

            SettingsSection("Agents") {
                Toggle("Let agents drive Scope", isOn: automation(\.agentsMayDrive))
                    .toggleStyle(.scope)
                Text("Requests from a thread Scope is running. Your own terminal is always allowed.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                SettingsRow("Open tasks") {
                    HStack(spacing: 8) {
                        Text("\(settings.maxAgentTasks)")
                            .foregroundStyle(Ink.primary)
                        ScopeStepper(value: settings.maxAgentTasks, range: AutomationSettings.budgetRange) {
                            automation(\.maxAgentTasks).wrappedValue = $0
                        }
                    }
                }
                SettingsRow("Running threads") {
                    HStack(spacing: 8) {
                        Text("\(settings.maxAgentThreads)")
                            .foregroundStyle(Ink.primary)
                        ScopeStepper(value: settings.maxAgentThreads, range: AutomationSettings.budgetRange) {
                            automation(\.maxAgentThreads).wrappedValue = $0
                        }
                    }
                }
                Text("How much agents may keep open at once, every scope together: tasks until they are archived, "
                     + "threads while they run. Any task may create tasks, so this is what stops a loop of agents "
                     + "starting agents. What you open yourself never counts.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Depth") {
                    HStack(spacing: 8) {
                        Text(depthCaption)
                            .foregroundStyle(Ink.primary)
                        ScopeStepper(value: settings.depthLimit ?? Self.noDepthLimit, range: 0...Self.noDepthLimit) { value in
                            automation(\.depthLimit).wrappedValue = value >= Self.noDepthLimit ? nil : value
                        }
                    }
                }
                Text("A thread you opened is at depth 0; what an agent opens from it is one deeper. Leave it without "
                     + "a limit unless you want agents fenced to a few generations.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Talking to threads") {
                    ScopePicker("Talking to threads", selection: automation(\.threadReach),
                                title: model.config.preferences.automationSettings.threadReach.title) {
                        ForEach(AutomationSettings.ThreadReach.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Text("Which threads an agent may read, type into, stop or close — in any task or scope, or only "
                     + "the ones it opened and those they opened in turn. A message from an agent always says which thread sent it.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Driver commands") {
                    ScopePicker("Driver commands", selection: automation(\.commandReach),
                                title: model.config.preferences.automationSettings.commandReach.title) {
                        ForEach(AutomationSettings.ThreadReach.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(model.config.preferences.automationSettings.threadReach == .own)
                    .usageID("command-reach", label: "Driver commands")
                }
                Text("Which threads an agent may hand a driver command to (`scope thread send --command`: /model, /clear, "
                     + "/compact), typed verbatim with no line saying who sent it. Never wider than Talking to threads.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Opening a thread") {
                    ScopePicker("Opening a thread", selection: automation(\.threads),
                                title: model.config.preferences.automationSettings.threads.title) {
                        ForEach(AutomationSettings.Approval.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                SettingsRow("Creating a task") {
                    ScopePicker("Creating a task", selection: automation(\.tasks),
                                title: model.config.preferences.automationSettings.tasks.title) {
                        ForEach(AutomationSettings.Approval.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Text("A task writes a branch and one worktree per repository. After asking shows one question at "
                     + "a time; one left unanswered past the timeout is refused.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsRow("Releases") {
                    ScopePicker("Releases", selection: automation(\.releases),
                                title: model.config.preferences.automationSettings.releases.title) {
                        ForEach(AutomationSettings.Approval.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .usageID("releases-approval", label: "Releases")
                }
                Text("`scope release` from an agent: Scope clones the repository's default branch under its own home "
                     + "and runs the release script there with your git identity, outside any sandbox. After asking by "
                     + "default — the one place Scope's autonomy default flips: a tag pushed is a version shipped, and "
                     + "nothing takes it back. A dry run never asks.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("Schedules") {
                Text("""
                    Prompts Scope sends on its own — every hour, every day, on weekdays or once a week — to a scope's \
                    orchestrator or into a new task. The reply lands in the Inbox. `scope schedule list` and \
                    `scope schedule run <name>` reach them too.
                    """)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.scopes.count > 1 {
                    SettingsRow("Scope") {
                        ScopePicker("Scope", selection: scheduleScopeBinding, title: scheduleScopeTitle) {
                            ForEach(model.scopes) { scope in Text(scope.name).tag(Optional(scope.id)) }
                        }
                        .usageID("schedule-scope", label: "Scope of the schedules shown")
                    }
                }
                if let scopeID = scheduleScope ?? model.currentScope?.id ?? model.scopes.first?.id {
                    ScheduleListEditor(scopeID: scopeID)
                } else {
                    Text("Declare a scope first.")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                }
                Toggle("Catch up at launch", isOn: Binding(
                    get: { model.config.preferences.catchUpSchedules },
                    set: { value in model.updatePreferences { $0.catchUpSchedules = value } }))
                    .toggleStyle(.scope)
                    .usageID("schedule-catch-up", label: "Catch up missed schedules at launch")
                Text("A daily, weekday or weekly prompt missed in the last day — the Mac was asleep at 09:00 — fires once "
                     + "when Scope opens. Hourly ones wait for the next hour.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("Socket") {
                SettingsRow("Path") {
                    Text(model.env.socketPath)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("The socket is 0600 in your Scope home: every program running as you can drive Scope "
                     + "through it, exactly as the driver hooks always could.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Bindings

    private var scheduleScopeBinding: Binding<ScopeID?> {
        Binding(get: { scheduleScope ?? model.currentScope?.id ?? model.scopes.first?.id }, set: { scheduleScope = $0 })
    }

    private var scheduleScopeTitle: String {
        let id = scheduleScope ?? model.currentScope?.id ?? model.scopes.first?.id
        return id.flatMap(model.scope)?.name ?? "Scope"
    }

    private func automation<Value>(_ keyPath: WritableKeyPath<AutomationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.config.preferences.automationSettings[keyPath: keyPath] },
            set: { value in
                model.updatePreferences { preferences in
                    var settings = preferences.automationSettings
                    settings[keyPath: keyPath] = value
                    preferences.automation = settings
                }
            }
        )
    }

    private var settings: AutomationSettings { model.config.preferences.automationSettings }

    /// The stepper's top step, which reads as no limit.
    private static let noDepthLimit = 10

    private var depthCaption: String {
        switch settings.depthLimit {
        case nil: "no limit"
        case 0: "0 — agents may not open threads or tasks"
        case 1: "1 — what an agent opens may not open more"
        case let depth?: "\(depth) generations"
        }
    }

    // MARK: Install

    private var toolPath: String? { ScopeCLILocator.embedded(in: Bundle.main.bundleURL) }

    private var destination: CLIInstaller.Destination {
        CLIInstaller.preferredDestination(home: model.env.home, debugBuild: BuildFlavor.isDebug)
    }

    private var isInstalled: Bool {
        guard let toolPath else { return false }
        if case .installed = CLIInstaller.state(of: destination, toolPath: toolPath) { return true }
        return false
    }

    private var linkState: String {
        guard let toolPath else { return "not in this build" }
        return switch CLIInstaller.state(of: destination, toolPath: toolPath) {
        case .installed(let link): link
        case .foreign(let link, _): "\(link) (not Scope's)"
        case .absent: "not installed"
        }
    }

    // MARK: MCP registration

    private var registration: MCPRegistration? {
        guard let toolPath else { return nil }
        let debug = BuildFlavor.isDebug
        return MCPRegistration(userHome: FileManager.default.homeDirectoryForCurrentUser, tool: toolPath,
                               scopeHome: model.env.home.path, debug: debug)
    }

    private func mcpCaption(_ state: MCPRegistration.State?) -> String {
        switch state {
        case nil: "…"
        case .unavailable: "not on this Mac"
        case .absent: "not registered"
        case .installed: "registered"
        case .stale: "points at another Scope"
        }
    }

    private func mcpActionTitle(_ state: MCPRegistration.State?) -> String? {
        switch state {
        case .absent: "Install"
        case .stale: "Repair"
        case .installed: "Remove"
        case nil, .unavailable: nil
        }
    }

    /// Reads where every client stands; `claude` is looked up on the login-shell PATH, like a driver.
    private func refreshMCP() async {
        let shell = await model.env.shell.environment()
        claudePath = ExecutableResolver.resolve("claude", path: shell.path, shell: shell.shell)
        guard let registration else { return }
        for client in MCPRegistration.Client.allCases {
            mcpStates[client] = registration.state(of: client, claudePath: claudePath)
        }
    }

    private func toggleMCP(_ client: MCPRegistration.Client) {
        guard var registration else { return }
        let installed = mcpStates[client] == .installed
        mcpBusy = true
        mcpFailure = nil
        Task {
            let shell = await model.env.shell.environment()
            registration = MCPRegistration(userHome: registration.userHome, tool: registration.tool,
                                           scopeHome: registration.scopeHome, debug: registration.name == "scope-debug",
                                           environment: shell.variables)
            do {
                if installed {
                    try await registration.remove(client, claudePath: claudePath)
                } else {
                    try await registration.install(client, claudePath: claudePath)
                }
            } catch {
                mcpFailure = String(describing: error)
            }
            await refreshMCP()
            mcpBusy = false
        }
    }

    // MARK: Skills

    private var skillInstaller: SkillInstaller {
        let debug = BuildFlavor.isDebug
        return SkillInstaller(userHome: FileManager.default.homeDirectoryForCurrentUser, debug: debug)
    }

    private func skillCaption(_ state: SkillInstaller.State?) -> String {
        switch state {
        case nil: "…"
        case .unavailable: "not on this Mac"
        case .absent: "not installed"
        case .installed: skillInstaller.skillDirectory(.claudeCode).path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        case .outdated: "installed, older text"
        case .foreign: "a skill of that name that is not Scope's"
        }
    }

    private func skillActionTitle(_ state: SkillInstaller.State?) -> String? {
        switch state {
        case nil, .unavailable, .foreign: nil
        case .absent: "Install"
        case .outdated: "Update"
        case .installed: "Remove"
        }
    }

    private func refreshSkills() {
        for client in SkillInstaller.Client.allCases {
            skillStates[client] = skillInstaller.state(of: client)
        }
    }

    private func toggleSkill(_ client: SkillInstaller.Client) {
        skillFailure = nil
        do {
            if skillStates[client] == .installed {
                try skillInstaller.remove(client)
            } else {
                try skillInstaller.install(client)
            }
        } catch {
            skillFailure = String(describing: error)
        }
        refreshSkills()
    }

    private func install() {
        guard let toolPath else { return }
        installFailure = nil
        do {
            let link = try CLIInstaller.install(toolPath: toolPath, to: destination, debugBuild: BuildFlavor.isDebug)
            installMessage = [
                "Linked \(link).",
                CLIInstaller.pathAdvice(for: destination),
            ].compactMap { $0 }.joined(separator: "\n")
        } catch let error as ControlError {
            installMessage = nil
            installFailure = error.description
        } catch {
            installMessage = nil
            installFailure = String(describing: error)
        }
    }
}
