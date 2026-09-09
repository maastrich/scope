import Foundation
import ScopeCore
import ScopeDrivers
import Testing

@Suite("DriverProfile")
struct DriverProfileTests {
    @Test("the four bundled profiles decode from Bundle.module and validate")
    func bundledProfilesDecode() throws {
        let profiles = try DriverRegistry.bundledProfiles()
        #expect(Set(profiles.map(\.id)) == ["shell", "claude-code", "codex", "cursor"])
        for profile in profiles {
            #expect(throws: Never.self) { try profile.validate() }
            #expect(profile.builtin == true)
            // The bundled revision only ever goes up; `installBuiltins` replaces an untouched older copy.
            #expect((profile.version ?? 0) >= 2)
            #expect(profile.icon != nil)
        }

        let shell = try #require(profiles.first { $0.id == "shell" })
        #expect(shell.command == "$SHELL")
        #expect(shell.isLoginShell)
        #expect(shell.args.isEmpty)
        #expect(shell.env.isEmpty)
        #expect(!shell.canResume)
        #expect(!shell.acceptsInitialPrompt)

        let claude = try #require(profiles.first { $0.id == "claude-code" })
        #expect(claude.command == "claude")
        #expect(claude.resume == ["claude", "--resume", "{resume_id}"])
        #expect(claude.headless == ["claude", "-p", "{prompt}", "--output-format", "json"])
        // The microsession runs the light model, and only read-only tools; the prompt stays ahead of
        // `--allowedTools`, which is variadic and would otherwise swallow it.
        let light = try #require(claude.headlessLight)
        #expect(claude.microsession == light)
        #expect(light.firstIndex(of: "{prompt}") == 2)
        #expect(light.contains("--model") && light.contains("haiku"))
        #expect(light.last?.contains("Bash(gh pr view:*)") == true)
        #expect(light.last?.contains("gh pr create") == false)
        #expect(claude.context == DriverProfile.Context(file: "CLAUDE.md", mode: .generate))
        #expect(claude.adapter?.kind == "claude-hooks")
        #expect(claude.canResume)
        #expect(!claude.isLoginShell)
        #expect(claude.prompt == ["{prompt}"] && claude.acceptsInitialPrompt)

        let codex = try #require(profiles.first { $0.id == "codex" })
        #expect(codex.context?.mode == .file)
        #expect(codex.adapter?.kind == "codex-notify")

        let cursor = try #require(profiles.first { $0.id == "cursor" })
        #expect(cursor.command == "cursor-agent")
        #expect(cursor.adapter?.kind == "cursor-hooks")
    }

    @Test("args and env default when absent; unknown keys are ignored")
    func minimalProfileDecodes() throws {
        let json = Data(#"{ "id": "mine", "name": "Mine", "command": "mine", "extra": 42 }"#.utf8)
        let profile = try JSONStore.makeDecoder().decode(DriverProfile.self, from: json)
        #expect(profile.args == [])
        #expect(profile.env == [:])
        #expect(profile.loginShell == nil)
        #expect(profile.context == nil)
        #expect(throws: Never.self) { try profile.validate() }
    }

    @Test("round-trips through JSONStore's encoder")
    func roundTrip() throws {
        let original = DriverProfile(
            id: "x-1", name: "X", command: "~/bin/x", args: ["--flag", "{cwd}"], env: ["A": "{home}"],
            loginShell: false, context: .init(file: "AGENTS.md", mode: .flag), resume: ["x", "{resume_id}"],
            headless: ["x", "-p", "{prompt}"], adapter: .init(kind: "k", options: ["o": "v"]),
            builtin: false, version: 3, icon: "cpu"
        )
        let data = try JSONStore.makeEncoder().encode(original)
        let decoded = try JSONStore.makeDecoder().decode(DriverProfile.self, from: data)
        #expect(decoded == original)
    }

    @Test("validate rejects bad ids", arguments: ["", "Shell", "-x", "a b", "a_b", "é"])
    func rejectsBadIDs(id: String) {
        let profile = DriverProfile(id: id, name: "X", command: "x")
        #expect(throws: DriverProfileError.invalidID(id)) { try profile.validate() }
    }

    @Test("validate accepts ids like shell, claude-code, x9")
    func acceptsGoodIDs() {
        for id in ["shell", "claude-code", "x9", "9x", "a-b-c"] {
            #expect(DriverProfile.isValidID(id), "\(id)")
        }
    }

    @Test("validate rejects an empty command")
    func rejectsEmptyCommand() {
        let profile = DriverProfile(id: "x", name: "X", command: "  ")
        #expect(throws: DriverProfileError.emptyCommand("x")) { try profile.validate() }
    }

    @Test("validate rejects unknown placeholders and names the field")
    func rejectsUnknownPlaceholders() {
        let inArgs = DriverProfile(id: "x", name: "X", command: "x", args: ["{nope}"])
        #expect(throws: DriverProfileError.badPlaceholder("nope", in: "args")) { try inArgs.validate() }

        let inEnv = DriverProfile(id: "x", name: "X", command: "x", env: ["K": "a{bad_one}b"])
        #expect(throws: DriverProfileError.badPlaceholder("bad_one", in: "env")) { try inEnv.validate() }

        let inResume = DriverProfile(id: "x", name: "X", command: "x", resume: ["x", "{session}"])
        #expect(throws: DriverProfileError.badPlaceholder("session", in: "resume")) { try inResume.validate() }

        let inHeadless = DriverProfile(id: "x", name: "X", command: "x", headless: ["x", "{q}"])
        #expect(throws: DriverProfileError.badPlaceholder("q", in: "headless")) { try inHeadless.validate() }
    }

    @Test("braces that are not {lowercase_name} are literal, not placeholders")
    func literalBraces() {
        let profile = DriverProfile(
            id: "x", name: "X", command: "x",
            args: ["{}", "{ \"json\": 1 }", "{Foo}", "{a-b}", "{", "}", "{{cwd}}"]
        )
        #expect(throws: Never.self) { try profile.validate() }
        #expect(DriverPlaceholder.referencedNames(in: "{{cwd}}") == ["cwd"])
        #expect(DriverPlaceholder.referencedNames(in: "{} {Foo} {a-b}") == [])
        #expect(DriverPlaceholder.referencedNames(in: "{thread_id}:{resume_id}") == ["thread_id", "resume_id"])
    }
}

@Suite("PlaceholderValues")
struct PlaceholderValuesTests {
    let values = PlaceholderValues(
        threadID: "3f9a2c17be04", resumeID: "sess-1", cwd: "/tmp/work", scope: "/tmp/scope",
        task: "/tmp/scope/task", home: "/tmp/home", prompt: "hello world"
    )

    @Test("expands every placeholder")
    func expandsAll() throws {
        let template = "{thread_id}|{resume_id}|{cwd}|{scope}|{task}|{home}|{prompt}"
        #expect(try values.expand(template) == "3f9a2c17be04|sess-1|/tmp/work|/tmp/scope|/tmp/scope/task|/tmp/home|hello world")
        #expect(try values.expand(["a", "{cwd}/b", "{{home}}"]) == ["a", "/tmp/work/b", "{/tmp/home}"])
        #expect(try values.expand(["K": "{scope}", "L": "plain"]) == ["K": "/tmp/scope", "L": "plain"])
    }

    @Test("a referenced placeholder without a value throws placeholderUnavailable")
    func nilValueThrows() {
        var missing = values
        missing.resumeID = nil
        missing.task = nil
        missing.prompt = nil
        #expect(throws: LaunchError.placeholderUnavailable(.resumeID)) { try missing.expand("claude --resume {resume_id}") }
        #expect(throws: LaunchError.placeholderUnavailable(.task)) { try missing.expand("{task}") }
        #expect(throws: LaunchError.placeholderUnavailable(.prompt)) { try missing.expand(["x", "{prompt}"]) }
        // Placeholders that always have a value keep working.
        #expect(throws: Never.self) { try missing.expand("{thread_id} {cwd} {scope} {home}") }
    }

    @Test("{thread_id} is accepted in resume argv (spec §5 form)")
    func threadIDAccepted() throws {
        let profile = DriverProfile(id: "x", name: "X", command: "x", resume: ["x", "--resume", "{thread_id}"])
        #expect(throws: Never.self) { try profile.validate() }
        #expect(try values.expand(profile.resume ?? []) == ["x", "--resume", "3f9a2c17be04"])
    }

    @Test("the prompt argv is appended on a fresh launch with an initial prompt only")
    func promptArgvAppended() throws {
        let profile = DriverProfile(id: "x", name: "X", command: "/bin/echo", args: ["--verbose"],
                                    resume: ["/bin/echo", "--resume", "{resume_id}"], prompt: ["{prompt}"])
        #expect(throws: DriverProfileError.badPlaceholder("nope", in: "prompt")) {
            try DriverProfile(id: "x", name: "X", command: "x", prompt: ["{nope}"]).validate()
        }
        let shell = ResolvedShellEnvironment(shell: "/bin/zsh", variables: ["PATH": "/usr/bin:/bin"], source: .login)
        let scope = TerminalEnvironment.ScopeVariables(thread: "3f9a2c17be04", scope: "acme", scopeRoot: "/tmp", sock: "/tmp/s", home: "/tmp")
        func plan(mode: LaunchMode, prompt: String?) throws -> LaunchPlan {
            var v = values
            v.cwd = "/tmp"
            v.prompt = prompt
            return try LaunchPlanner.plan(profile: profile, mode: mode, values: v, shellEnvironment: shell, scopeVariables: scope,
                                          appVersion: "0.1.0", adapterArguments: ["--settings", "s.json"])
        }
        #expect(try plan(mode: .launch, prompt: "Add login").arguments == ["--verbose", "Add login", "--settings", "s.json"])
        #expect(try plan(mode: .launch, prompt: nil).arguments == ["--verbose", "--settings", "s.json"])
        #expect(try plan(mode: .resume, prompt: "Add login").arguments == ["--resume", "sess-1", "--settings", "s.json"])
    }

    @Test("unknown names and stray braces pass through unchanged")
    func unknownNamesPassThrough() throws {
        #expect(try values.expand("{unknown} {} {Foo} {") == "{unknown} {} {Foo} {")
        #expect(try values.expand("") == "")
    }
}
