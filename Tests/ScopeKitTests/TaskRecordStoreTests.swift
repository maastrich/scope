import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

@Suite struct TaskRecordStoreTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-tasks-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func record(name: String, createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> TaskRecord {
        TaskRecord(
            scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/tmp/acme", scopeSlug: "acme", scopeName: "Acme",
            name: name, slug: slugify(name), branch: "scope/\(slugify(name))", root: "/tmp/home/sandboxes/acme/\(slugify(name))",
            repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/tmp/home/sandboxes/acme/\(slugify(name))/api", branch: "scope/\(slugify(name))")],
            createdAt: createdAt
        )
    }

    @Test func roundTripAndOrdering() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let older = record(name: "Older", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = record(name: "Newer", createdAt: Date(timeIntervalSince1970: 1_700_000_500.25))
        try await store.save(newer)
        try await store.save(older)

        #expect(FileManager.default.fileExists(atPath: store.url(for: older.id).path))
        let loaded = await store.loadAll()
        #expect(loaded.problems.isEmpty)
        #expect(loaded.records == [older, newer])
        #expect(loaded.records[1].createdAt == newer.createdAt)   // fractional seconds survive

        try await store.delete(older.id)
        try await store.delete(older.id)   // idempotent
        #expect(await store.loadAll().records == [newer])
    }

    @Test func corruptFileIsQuarantinedAndReported() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        let good = record(name: "Good")
        try await store.save(good)
        let badID = TaskID.generate()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.url(for: badID))
        try Data("{}".utf8).write(to: store.directory.appending(path: "notes.json"))   // ignored: not an id

        let loaded = await store.loadAll()
        #expect(loaded.records == [good])
        #expect(loaded.problems.count == 1)
        #expect(loaded.problems[0].message.hasPrefix("corrupt JSON"))
        #expect(loaded.problems[0].backup?.lastPathComponent.contains("corrupt-") == true)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: badID).path))
    }

    @Test func newerSchemaVersionIsSkippedAndNeverOverwritten() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        var future = record(name: "Future")
        future.version = TaskRecord.currentVersion + 1
        try JSONStore.save(future, to: store.url(for: future.id), fractionalSeconds: true)
        let original = try Data(contentsOf: store.url(for: future.id))

        let loaded = await store.loadAll()
        #expect(loaded.records.isEmpty)
        #expect(loaded.problems.count == 1 && loaded.problems[0].message.contains("newer"))

        future.version = TaskRecord.currentVersion
        future.name = "Rewritten"
        try await store.save(future)
        #expect(try Data(contentsOf: store.url(for: future.id)) == original)
    }

    @Test func lenientDecodingAndDerivedProperties() throws {
        let json = """
        {"version":1,"id":"3f9a2c17be04","scopeID":"8D0C1F9E-4B6A-4C62-9C3F-2D1E7A5B9F10","slug":"auth","branch":"scope/auth","root":"/r/auth"}
        """
        let decoded = try JSONStore.makeDecoder(fractionalSeconds: true).decode(TaskRecord.self, from: Data(json.utf8))
        #expect(decoded.name == "auth" && decoded.repos.isEmpty && decoded.archivedAt == nil)
        #expect(decoded.threadCwd.path == "/r/auth")
        #expect(decoded.environment == ["SCOPE_TASK": "auth", "SCOPE_TASK_ROOT": "/r/auth"])

        let multi = record(name: "Multi")
        #expect(multi.threadCwd.path == multi.repos[0].sandboxPath)   // one active repo → the sandbox
        var two = multi
        two.repos.append(TaskRepo(repoRelativePath: "web/", sandboxPath: "/s/web", branch: "scope/multi"))
        #expect(two.repos[1].repoRelativePath == "web")
        #expect(two.threadCwd.path == two.root)                       // two repos → the task root
        two.repos[1].state = .archived
        #expect(two.threadCwd.path == multi.repos[0].sandboxPath)
        #expect(TaskRepo.normalize("./") == "." && TaskRepo.normalize("") == "." && TaskRepo.normalize("./a/b/") == "a/b")
        #expect(TaskID(rawValue: "ZZZ") == nil)
    }
}
