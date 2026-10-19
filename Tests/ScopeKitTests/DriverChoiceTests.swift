import Foundation
import ScopeCore
import ScopeDrivers
import Testing

@Suite("DriverChoice")
struct DriverChoiceTests {
    static let shell = DriverProfile(id: "shell", name: "Shell", command: "$SHELL", loginShell: true)
    static let plain = DriverProfile(id: "claude-code", name: "Claude Code", command: "claude", modelArgs: ["--model", "{model}"])
    static let bypass = DriverProfile(id: "claude-code-bypass", name: "Claude Code (bypass)", command: "claude",
                                      args: ["--dangerously-skip-permissions"],
                                      env: ["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD": "1"],
                                      resume: ["claude", "--resume", "{resume_id}", "--dangerously-skip-permissions"],
                                      prompt: ["{prompt}"], modelArgs: ["--model", "{model}"])
    static let fable = DriverProfile(id: "claude-code-fable", name: "Claude Code (Fable)", command: "claude",
                                     args: ["--model", "claude-fable-5-1"])
    static let profiles = [shell, plain, bypass, fable]

    @Test("the Settings default wins when nothing names a driver: an agent, the CLI, the MCP server pass none")
    func preferenceWins() {
        #expect(DriverChoice.resolve(preference: "claude-code-bypass", profiles: Self.profiles)?.id == "claude-code-bypass")
        #expect(DriverChoice.resolve(requested: nil, preference: "claude-code-bypass", profiles: Self.profiles)?.id == "claude-code-bypass")
        #expect(DriverChoice.resolve(requested: "", preference: "claude-code-bypass", profiles: Self.profiles)?.id == "claude-code-bypass")
    }

    @Test("the driver last opened in the scope never overrides the preference")
    func lastOpenedNeverOverridesPreference() {
        // An agent's creation: the UI memory is not even consulted.
        #expect(DriverChoice.resolve(preference: "claude-code-bypass", lastOpened: nil, profiles: Self.profiles)?.id == "claude-code-bypass")
        // The user's own ⌘T, with a preference set: the preference still wins over what was opened last.
        #expect(DriverChoice.resolve(preference: "claude-code-bypass", lastOpened: "claude-code-fable",
                                     profiles: Self.profiles)?.id == "claude-code-bypass")
    }

    @Test("Automatic: the user's ⌘T keeps the driver last opened, an agent gets the first agent profile")
    func automaticFallsBackOnLastOpenedForTheUserOnly() {
        #expect(DriverChoice.resolve(preference: "", lastOpened: "claude-code-fable", profiles: Self.profiles)?.id == "claude-code-fable")
        #expect(DriverChoice.resolve(preference: "", profiles: Self.profiles)?.id == "claude-code")
        // The shell is a choice, never the fallback; it is only reached when nothing else is installed.
        #expect(DriverChoice.resolve(preference: "", profiles: [Self.shell, Self.plain])?.id == "claude-code")
        #expect(DriverChoice.resolve(preference: "", profiles: [Self.shell])?.id == "shell")
        #expect(DriverChoice.resolve(preference: "", profiles: []) == nil)
    }

    @Test("an explicit driver wins; one that is not installed falls through to the preference")
    func requestedWins() {
        #expect(DriverChoice.resolve(requested: "codex", preference: "claude-code-bypass", profiles: Self.profiles)?.id == "claude-code-bypass")
        #expect(DriverChoice.resolve(requested: "shell", preference: "claude-code-bypass", profiles: Self.profiles)?.id == "shell")
        #expect(DriverChoice.resolve(requested: "claude-code", preference: "claude-code-bypass", lastOpened: "claude-code-fable",
                                     profiles: Self.profiles)?.id == "claude-code")
        // A preference pointing at a profile that was removed is not an error: automatic takes over.
        #expect(DriverChoice.resolve(preference: "gone", lastOpened: "claude-code-fable", profiles: Self.profiles)?.id == "claude-code-fable")
    }

    @Test("a model is added on top of the bypass profile: its flags and env stay, on launch and on resume")
    func modelKeepsTheProfileFlags() throws {
        let shell = ResolvedShellEnvironment(shell: "/bin/zsh", variables: ["PATH": "/usr/bin:/bin"], source: .login)
        let scope = TerminalEnvironment.ScopeVariables(thread: "3f9a2c17be04", scope: "acme", scopeRoot: "/tmp", sock: "/tmp/s", home: "/tmp")
        // The bundled profile as shipped, with a command the planner can resolve on this PATH.
        var profile = try #require(DriverRegistry.bundledProfiles().first { $0.id == "claude-code-bypass" })
        profile.command = "/bin/echo"
        profile.resume = ["/bin/echo", "--resume", "{resume_id}", "--dangerously-skip-permissions"]
        func plan(mode: LaunchMode, model: String?) throws -> LaunchPlan {
            let values = PlaceholderValues(threadID: "3f9a2c17be04", resumeID: "sess-1", cwd: "/tmp", scope: "/tmp",
                                           task: nil, home: "/tmp", prompt: "Add login", model: model)
            return try LaunchPlanner.plan(profile: profile, mode: mode, values: values, shellEnvironment: shell,
                                          scopeVariables: scope, appVersion: "0.1.0", fileExists: { _ in true })
        }
        let launch = try plan(mode: .launch, model: "claude-fable-5-1")
        #expect(launch.arguments == ["--dangerously-skip-permissions", "--model", "claude-fable-5-1", "Add login"])
        #expect(launch.environment["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] == "1")
        let resume = try plan(mode: .resume, model: "claude-fable-5-1")
        #expect(resume.arguments == ["--resume", "sess-1", "--dangerously-skip-permissions", "--model", "claude-fable-5-1"])
        #expect(resume.environment["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] == "1")
        // No model: the profile alone, nothing lost either way.
        #expect(try plan(mode: .launch, model: nil).arguments == ["--dangerously-skip-permissions", "Add login"])
    }
}
