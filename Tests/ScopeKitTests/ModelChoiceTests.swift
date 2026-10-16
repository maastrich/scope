import Foundation
import Testing
@testable import ScopeCore
@testable import ScopeDrivers

/// Which model a thread opens on, and how a profile passes it (spec §5).
@Suite struct ModelChoiceTests {
    @Test("the request wins, then what the caller runs on, then the scope, then the driver's default")
    func precedence() {
        #expect(ModelChoice.resolve(requested: "a", inherited: "b", scopeDefault: "c", driverDefault: "d") == "a")
        #expect(ModelChoice.resolve(inherited: "b", scopeDefault: "c", driverDefault: "d") == "b")
        #expect(ModelChoice.resolve(scopeDefault: "c", driverDefault: "d") == "c")
        #expect(ModelChoice.resolve(driverDefault: "d") == "d")
        #expect(ModelChoice.resolve() == nil)
        // Blank is nothing said, not a model called "".
        #expect(ModelChoice.resolve(requested: "  ", scopeDefault: "", driverDefault: " d ") == "d")
    }

    @Test("an agent passes its model on to threads of its own driver only")
    func inheritance() {
        #expect(ModelChoice.inherited(callerModel: "claude-fable-5-1", callerDriver: "claude-code", driver: "claude-code") == "claude-fable-5-1")
        #expect(ModelChoice.inherited(callerModel: "claude-fable-5-1", callerDriver: "claude-code", driver: "codex") == nil)
        #expect(ModelChoice.inherited(callerModel: nil, callerDriver: "claude-code", driver: "claude-code") == nil)
    }

    @Test("modelArgs go after args on a launch and after the resume argv, before the prompt; nothing without a model")
    func modelArgvPlacement() throws {
        let profile = DriverProfile(id: "x", name: "X", command: "/bin/echo", args: ["--verbose"],
                                    resume: ["/bin/echo", "--resume", "{resume_id}"], prompt: ["{prompt}"],
                                    modelArgs: ["--model", "{model}"], models: ["one", " two ", "", "one"])
        #expect(throws: Never.self) { try profile.validate() }
        #expect(profile.acceptsModel)
        #expect(profile.knownModels == ["one", "two"])
        let shell = ResolvedShellEnvironment(shell: "/bin/zsh", variables: ["PATH": "/usr/bin:/bin"], source: .login)
        let scope = TerminalEnvironment.ScopeVariables(thread: "3f9a2c17be04", scope: "acme", scopeRoot: "/tmp", sock: "/tmp/s", home: "/tmp")
        func plan(mode: LaunchMode, model: String?) throws -> [String] {
            let values = PlaceholderValues(threadID: "3f9a2c17be04", resumeID: "sess-1", cwd: "/tmp", scope: "/tmp", home: "/tmp",
                                           prompt: "Add login", model: model)
            return try LaunchPlanner.plan(profile: profile, mode: mode, values: values, shellEnvironment: shell, scopeVariables: scope,
                                          appVersion: "0.1.0").arguments
        }
        #expect(try plan(mode: .launch, model: "claude-opus-5-5") == ["--verbose", "--model", "claude-opus-5-5", "Add login"])
        #expect(try plan(mode: .resume, model: "claude-opus-5-5") == ["--resume", "sess-1", "--model", "claude-opus-5-5"])
        #expect(try plan(mode: .launch, model: nil) == ["--verbose", "Add login"])
        #expect(try plan(mode: .launch, model: "") == ["--verbose", "Add login"])
    }

    @Test("a profile without modelArgs takes no model and {model} is checked like any placeholder")
    func profileWithoutModelArgs() {
        let shell = DriverProfile(id: "shell", name: "Shell", command: "$SHELL")
        #expect(!shell.acceptsModel)
        #expect(shell.argv(["sh"], model: "anything") == ["sh"])
        #expect(throws: DriverProfileError.badPlaceholder("modle", in: "modelArgs")) {
            try DriverProfile(id: "x", name: "X", command: "x", modelArgs: ["--model", "{modle}"]).validate()
        }
    }

    @Test("the bundled agent profiles say how a model is passed; the shell does not")
    func bundledProfiles() throws {
        let profiles = try DriverRegistry.bundledProfiles()
        for id in ["claude-code", "claude-code-bypass", "codex", "cursor"] {
            let profile = try #require(profiles.first { $0.id == id })
            #expect(profile.modelArgs == ["--model", "{model}"], "\(id)")
        }
        #expect(try #require(profiles.first { $0.id == "claude-code" }).knownModels.contains("claude-fable-5-1"))
        #expect(try #require(profiles.first { $0.id == "shell" }).acceptsModel == false)
    }

    @Test("the thread record keeps the model, and an old record has none")
    func threadRecordKeepsTheModel() throws {
        let id = try #require(ThreadID(rawValue: "3f9a2c17be04"))
        let record = ThreadRecord(id: id, scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/tmp",
                                  driverID: "claude-code", title: "acme", cwd: "/tmp", cwdKind: .scopeRoot, model: "claude-fable-5-1")
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ThreadRecord.self, from: data).model == "claude-fable-5-1")
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "model")
        let old = try JSONDecoder().decode(ThreadRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.model == nil)
    }

    @Test("the scope's and the drivers' defaults survive a config without them")
    func configDefaults() throws {
        let declaration = try JSONDecoder().decode(ScopeDeclaration.self, from: Data(
            #"{"id":"8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10","path":"/tmp","slug":"acme","model":""}"#.utf8))
        #expect(declaration.model == nil)
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"driverModels":{"claude-code":"claude-opus-5-5"}}"#.utf8))
        #expect(preferences.driverModels == ["claude-code": "claude-opus-5-5"])
        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).driverModels.isEmpty)
    }
}
