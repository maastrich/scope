import Foundation
import ScopeCore
import ScopeDrivers
import Testing

/// A throwaway `SCOPE_HOME`; removed by `remove()`.
private struct DriverTestHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "scope-drivers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var drivers: URL { ScopeHome.driversURL(home: url) }

    func write(_ name: String, _ contents: String) throws {
        try FileManager.default.createDirectory(at: drivers, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: drivers.appending(path: name))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("DriverRegistry")
struct DriverRegistryTests {
    @Test("installBuiltins copies the four bundled files once and never overwrites a user edit")
    func installBuiltins() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        let registry = DriverRegistry(home: home.url)

        let installed = try await registry.installBuiltins()
        #expect(Set(installed) == ["shell", "claude-code", "codex", "cursor"])
        let files = try FileManager.default.contentsOfDirectory(atPath: home.drivers.path).sorted()
        #expect(files == ["claude-code.json", "codex.json", "cursor.json", "shell.json"])

        // A copied file is the bundled one, kept pretty and human-editable (multi-line).
        let bundledShell = try #require(DriverRegistry.bundledProfiles().first { $0.id == "shell" })
        let copied = home.drivers.appending(path: "shell.json")
        #expect(try JSONStore.load(DriverProfile.self, from: copied) == bundledShell)
        #expect(try String(contentsOf: copied, encoding: .utf8).contains("\n"))

        // User edit survives a second install.
        let edited = #"{ "id": "shell", "name": "My Shell", "command": "$SHELL", "loginShell": true }"#
        try home.write("shell.json", edited)
        let second = try await registry.installBuiltins()
        #expect(second.isEmpty)
        #expect(try String(contentsOf: home.drivers.appending(path: "shell.json"), encoding: .utf8) == edited)
    }

    @Test("installBuiltins replaces an untouched older bundled copy, keeps an edited one")
    func upgradeStaleBuiltin() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        let registry = DriverRegistry(home: home.url)
        // A copy shipped by an older build: still `builtin`, lower version → replaced.
        try home.write("claude-code.json", #"{ "id": "claude-code", "name": "Claude Code", "command": "claude", "builtin": true, "version": 1 }"#)
        // A user edit that kept `builtin` but bumped the version past the bundled one → kept.
        try home.write("codex.json", #"{ "id": "codex", "name": "My Codex", "command": "codex", "builtin": true, "version": 99 }"#)
        // A user edit that dropped `builtin` → kept.
        try home.write("cursor.json", #"{ "id": "cursor", "name": "My Cursor", "command": "cursor-agent" }"#)

        let installed = try await registry.installBuiltins()
        #expect(Set(installed) == ["shell", "claude-code"])
        let loaded = await registry.load()
        #expect(loaded.profile(id: "claude-code")?.prompt == ["{prompt}"])
        #expect(loaded.profile(id: "claude-code")?.version == 2)
        #expect(loaded.profile(id: "codex")?.name == "My Codex")
        #expect(loaded.profile(id: "cursor")?.name == "My Cursor")
    }

    @Test("load without a drivers directory returns the bundled profiles, shell first, no problems")
    func loadBundledOnly() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        let loaded = await DriverRegistry(home: home.url).load()
        #expect(loaded.problems.isEmpty)
        #expect(loaded.profiles.map(\.id) == ["shell", "claude-code", "codex", "cursor"])
        #expect(loaded.profile(id: "codex")?.name == "Codex CLI")
        #expect(loaded.profile(id: "nope") == nil)
    }

    @Test("a valid user file wins over the bundled profile with the same id")
    func userOverride() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        try home.write("claude-code.json", #"{ "id": "claude-code", "name": "Claude (mine)", "command": "/opt/claude", "args": ["--verbose"] }"#)

        let loaded = await DriverRegistry(home: home.url).load()
        #expect(loaded.problems.isEmpty)
        let claude = try #require(loaded.profile(id: "claude-code"))
        #expect(claude.name == "Claude (mine)")
        #expect(claude.command == "/opt/claude")
        #expect(claude.args == ["--verbose"])
        #expect(claude.builtin == nil)
        #expect(loaded.profiles.count == 4)
    }

    @Test("an invalid user file is reported and the bundled profile is used instead")
    func invalidUserFileFallsBack() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        try home.write("codex.json", "{ not json")
        try home.write("cursor.json", #"{ "id": "cursor", "name": "Cursor", "command": "" }"#)
        try home.write("notes.txt", "ignored")

        let loaded = await DriverRegistry(home: home.url).load()
        #expect(loaded.problems.count == 2)
        #expect(loaded.problems.map(\.file.lastPathComponent).sorted() == ["codex.json", "cursor.json"])
        #expect(loaded.problems.allSatisfy { $0.message.contains("bundled") })
        #expect(loaded.profile(id: "codex")?.builtin == true)
        #expect(loaded.profile(id: "cursor")?.command == "cursor-agent")
        #expect(loaded.profiles.count == 4)
    }

    @Test("an extra user profile appears, sorted by name after shell")
    func extraUserProfile() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        try home.write("aider.json", #"{ "id": "aider", "name": "Aider", "command": "aider" }"#)
        try home.write("zeta.json", #"{ "id": "zeta", "name": "Zeta", "command": "zeta" }"#)

        let loaded = await DriverRegistry(home: home.url).load()
        #expect(loaded.problems.isEmpty)
        #expect(loaded.profiles.map(\.id) == ["shell", "aider", "claude-code", "codex", "cursor", "zeta"])
    }

    @Test("a file whose id does not match its name is reported and skipped")
    func idFileNameMismatch() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        try home.write("other.json", #"{ "id": "aider", "name": "Aider", "command": "aider" }"#)

        let loaded = await DriverRegistry(home: home.url).load()
        #expect(loaded.problems.count == 1)
        #expect(loaded.problems.first?.message.contains("aider.json") == true)
        #expect(loaded.profile(id: "aider") == nil)
    }

    @Test("load is cached; reload picks up new files")
    func reloadRefreshes() async throws {
        let home = try DriverTestHome()
        defer { home.remove() }
        let registry = DriverRegistry(home: home.url)
        #expect(await registry.load().profiles.count == 4)

        try home.write("aider.json", #"{ "id": "aider", "name": "Aider", "command": "aider" }"#)
        #expect(await registry.load().profiles.count == 4)
        #expect(await registry.reload().profiles.count == 5)
        #expect(await registry.load().profiles.count == 5)
    }
}
