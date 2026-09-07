import Foundation
import Testing
@testable import ScopeCore

private func makeTempHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appending(path: "scope-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try ScopeHome.ensureLayout(at: home)
    return home
}

private func sampleConfig(home: URL) -> ScopeConfig {
    let acme = ScopeDeclaration(
        path: home.appending(path: "acme").path,
        slug: "acme",
        discoveryDepth: 1,
        id: ScopeID(rawValue: "8D0C1F9E-4B6A-4C62-9C3F-2D1E7A5B9F10"),
        addedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let scope = ScopeDeclaration(
        path: home.appending(path: "@maastrich/scope/").path,
        name: "Scope app",
        slug: "scope",
        discoveryDepth: 9,                     // clamped to 4
        sandboxes: .insideScope,
        addedAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
    var preferences = Preferences.default
    preferences.editor = EditorTemplate(argv: ["cursor", "-g", "{file}:{line}"])
    preferences.confirmQuitWithRunningThreads = false
    return ScopeConfig(scopes: [acme, scope], preferences: preferences)
}

@Suite struct ConfigStoreTests {
    @Test func missingFileLoadsEmptyWithoutWriting() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home)

        let loaded = await store.load()
        #expect(loaded.config == .empty)
        #expect(loaded.problem == nil)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        #expect(store.url.path == ScopeHome.configURL(home: home).path)
    }

    @Test func savesAreCoalescedToTheLastValue() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home, saveDelay: .milliseconds(60))

        var config = ScopeConfig.empty
        for prefix in ["one", "two", "three"] {
            config.preferences.branchPrefix = prefix
            await store.save(config)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))

        #expect(await store.writeCount == 1)
        let onDisk = try JSONStore.load(ScopeConfig.self, from: store.url)
        #expect(onDisk.preferences.branchPrefix == "three")
    }

    @Test func flushWritesImmediatelyAndOnlyWhenPending() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home, saveDelay: .seconds(5))

        await store.flush()
        #expect(await store.writeCount == 0)

        await store.save(sampleConfig(home: home))
        await store.flush()
        #expect(await store.writeCount == 1)
        #expect(FileManager.default.fileExists(atPath: store.url.path))

        await store.flush()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await store.writeCount == 1)   // the cancelled timer does not write a second time
    }

    @Test func roundTripThroughDisk() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home)
        let config = sampleConfig(home: home)

        await store.save(config)
        await store.flush()
        let loaded = await store.load()

        #expect(loaded.problem == nil)
        #expect(loaded.config == config)
        #expect(loaded.config.scopes[1].discoveryDepth == 4)
        #expect(loaded.config.scopes[1].name == "Scope app")
        #expect(loaded.config.scopes[0].name == "acme")
        #expect(!loaded.config.scopes[1].path.hasSuffix("/"))
        #expect(loaded.config.scopes[0].id.rawValue == "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")

        let text = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        #expect(text.contains("\"version\" : 1"))
        #expect(text.contains("\"sandboxes\" : \"insideScope\""))
        #expect(text.contains("\"shellProbe\" : \"interactiveLogin\""))
    }

    @Test func corruptFileIsQuarantinedAndReported() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home)
        try Data("{ \"version\": 1, \"scopes\": [ oops".utf8).write(to: store.url)

        let loaded = await store.load()
        #expect(loaded.config == .empty)
        guard case .corrupt(let backup, let underlying)? = loaded.problem else {
            Issue.record("expected .corrupt, got \(String(describing: loaded.problem))")
            return
        }
        #expect(!underlying.isEmpty)
        #expect(backup.lastPathComponent.hasPrefix("config.corrupt-"))
        #expect(backup.pathExtension == "json")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: store.url.path))

        // The store is usable again: a fresh document is written.
        #expect(await store.isReadOnly == false)
        await store.save(sampleConfig(home: home))
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func newerSchemaVersionIsRefusedAndNeverOverwritten() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home)
        let original = Data("{\n  \"version\" : 2,\n  \"scopes\" : [],\n  \"future\" : true\n}\n".utf8)
        try original.write(to: store.url)

        let loaded = await store.load()
        #expect(loaded.config == .empty)
        #expect(loaded.problem == .unsupportedVersion(2))
        #expect(await store.isReadOnly)

        await store.save(sampleConfig(home: home))
        await store.flush()
        #expect(await store.writeCount == 0)
        #expect(try Data(contentsOf: store.url) == original)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix("config") }
        #expect(siblings == ["config.json"])   // no quarantine copy either
    }

    @Test func partialDocumentDecodesWithDefaults() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home)
        let json = """
        {
          "version" : 1,
          "scopes" : [
            { "id" : "5a7e2b11-9f0d-4d3c-8e21-0c4b6f7a1d22", "path" : "\(home.path)/x/", "slug" : "x", "unknownKey" : 1 }
          ],
          "preferences" : { "branchPrefix" : "wip" }
        }
        """
        try Data(json.utf8).write(to: store.url)

        let loaded = await store.load()
        #expect(loaded.problem == nil)
        let scope = try #require(loaded.config.scopes.first)
        #expect(scope.name == "x")
        #expect(scope.discoveryDepth == 1)
        #expect(scope.sandboxes == .home)
        #expect(scope.path == home.appending(path: "x").path)
        #expect(loaded.config.preferences.branchPrefix == "wip")
        #expect(loaded.config.preferences.defaultDriverID == "shell")
        #expect(loaded.config.preferences.editor == nil)
    }

    @Test func documentWithoutVersionIsCorrupt() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ConfigStore(home: home)
        try Data("{ \"scopes\" : [] }".utf8).write(to: store.url)

        let loaded = await store.load()
        guard case .corrupt? = loaded.problem else {
            Issue.record("expected .corrupt, got \(String(describing: loaded.problem))")
            return
        }
    }
}

@Suite struct ScopeConfigLookupTests {
    @Test func scopeByPathComparesResolvedPaths() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: "acme")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = ScopeConfig(scopes: [ScopeDeclaration(path: folder.path, slug: "acme")])

        #expect(config.scope(path: folder.path) != nil)
        #expect(config.scope(path: folder.path + "/") != nil)
        #expect(config.scope(path: folder.resolvingSymlinksInPath().path) != nil)
        if !folder.path.hasPrefix("/private") {
            // /var/folders/... vs /private/var/folders/... on macOS
            #expect(config.scope(path: "/private" + folder.path) != nil)
        }
        #expect(config.scope(path: home.appending(path: "other").path) == nil)
        #expect(config.scope(id: config.scopes[0].id) == config.scopes[0])
        #expect(config.scope(id: .generate()) == nil)
        #expect(config.takenSlugs == ["acme"])
    }

    @Test func declarationNormalizesInput() {
        let declaration = ScopeDeclaration(path: "~/Projects/acme/", slug: "acme", discoveryDepth: -3)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(declaration.path == homeDirectory + "/Projects/acme")
        #expect(declaration.name == "acme")
        #expect(declaration.discoveryDepth == 0)
        #expect(declaration.url.hasDirectoryPath)
    }
}

@Suite struct EditorTemplateExpansionTests {
    let template = EditorTemplate(argv: ["code", "-g", "{file}:{line}"])

    @Test func fileAndLine() {
        #expect(template.expand(path: "/repo", file: "src/a.swift", line: 12) == ["code", "-g", "/repo/src/a.swift:12"])
        #expect(template.expand(path: "/repo", file: "/abs/a.swift", line: 3) == ["code", "-g", "/abs/a.swift:3"])
    }

    @Test func fileWithoutLineDropsTheSuffix() {
        #expect(template.expand(path: "/repo", file: "a.swift") == ["code", "-g", "/repo/a.swift"])
        let separate = EditorTemplate(argv: ["idea", "--line", "{line}", "{file}"])
        #expect(separate.expand(path: "/repo", file: "a.swift") == ["idea", "/repo/a.swift"])
        #expect(separate.expand(path: "/repo", file: "a.swift", line: 4) == ["idea", "--line", "4", "/repo/a.swift"])
    }

    @Test func folderOnly() {
        #expect(template.expand(path: "/repo") == ["code", "-g", "/repo"])
        #expect(EditorTemplate(argv: ["open", "-a", "Xcode", "{path}"]).expand(path: "/repo") == ["open", "-a", "Xcode", "/repo"])
        #expect(EditorTemplate(argv: ["subl"]).expand(path: "/repo") == ["subl", "/repo"])
    }

    @Test func fileAppendedWhenTemplateOnlyMentionsPath() {
        #expect(EditorTemplate(argv: ["subl", "{path}"]).expand(path: "/repo", file: "a.swift") == ["subl", "/repo", "/repo/a.swift"])
    }
}
