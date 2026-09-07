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

private let scopeID = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")

private func makeRecord(
    id: String,
    createdAt: TimeInterval,
    cwdKind: ThreadCwdKind = .scopeRoot,
    driverID: String = "shell"
) throws -> ThreadRecord {
    let threadID = try #require(ThreadID(rawValue: id))
    return ThreadRecord(
        id: threadID,
        scopeID: scopeID,
        scopeRoot: "/Users/me/contributions/acme",
        driverID: driverID,
        title: "Shell · acme",
        cwd: "/Users/me/contributions/acme",
        cwdKind: cwdKind,
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}

@Suite struct ThreadRecordStoreTests {
    @Test func emptyDirectoryAndMissingDirectory() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let store = ThreadRecordStore(home: home)
        let loaded = await store.loadAll()
        #expect(loaded.records.isEmpty)
        #expect(loaded.problems.isEmpty)

        let orphan = ThreadRecordStore(home: home.appending(path: "nowhere"))
        let none = await orphan.loadAll()
        #expect(none.records.isEmpty)
        #expect(none.problems.isEmpty)
    }

    @Test func saveLoadSortedByCreationAndDelete() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)

        var second = try makeRecord(id: "aaaaaaaaaaa2", createdAt: 1_800_000_001.250, cwdKind: .repoBase(relativePath: "api"))
        second.launchCount = 2
        second.lastLaunchedAt = Date(timeIntervalSince1970: 1_800_000_050.008)
        second.lastExit = ExitStatus(code: 0, signal: nil, at: Date(timeIntervalSince1970: 1_800_000_040.130))
        second.resumeID = "sess-42"
        second.log = home.appending(path: "logs/aaaaaaaaaaa2.log").path
        let third = try makeRecord(id: "aaaaaaaaaaa3", createdAt: 1_800_000_001.750, cwdKind: .task(slug: "auth-refresh"))
        let first = try makeRecord(id: "aaaaaaaaaaa1", createdAt: 1_800_000_000)

        await store.save(third)
        await store.save(first)
        await store.save(second)

        let loaded = await store.loadAll()
        #expect(loaded.problems.isEmpty)
        #expect(loaded.records == [first, second, third])   // fractional seconds survive
        #expect(loaded.records.map(\.fileName) == ["aaaaaaaaaaa1.json", "aaaaaaaaaaa2.json", "aaaaaaaaaaa3.json"])

        let text = String(decoding: try Data(contentsOf: store.url(for: second.id)), as: UTF8.self)
        #expect(text.contains("\"createdAt\" : \"2027-01-15T08:00:01.250Z\""))
        #expect(text.contains("\"repoBase\" : {"))
        #expect(text.contains("\"relativePath\" : \"api\""))
        #expect(text.contains("\"scopeRoot\" : \"/Users/me/contributions/acme\""))
        #expect(text.contains("\"version\" : 1"))

        await store.delete(second.id)
        await store.delete(second.id)   // already gone: no error
        let remaining = await store.loadAll()
        #expect(remaining.records.map(\.id) == [first.id, third.id])
    }

    @Test func tiesOnCreatedAtAreOrderedByID() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        await store.save(try makeRecord(id: "bbbbbbbbbbbb", createdAt: 1_800_000_000))
        await store.save(try makeRecord(id: "aaaaaaaaaaaa", createdAt: 1_800_000_000))

        let loaded = await store.loadAll()
        #expect(loaded.records.map(\.id.rawValue) == ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
    }

    @Test func corruptFileIsQuarantinedAndOthersStillLoad() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        let good = try makeRecord(id: "aaaaaaaaaaaa", createdAt: 1_800_000_000)
        await store.save(good)
        let badID = try #require(ThreadID(rawValue: "bbbbbbbbbbbb"))
        try Data("{ \"version\": 1, \"id\": \"bbbbbbbbbbbb\", ".utf8).write(to: store.url(for: badID))

        let loaded = await store.loadAll()
        #expect(loaded.records == [good])
        #expect(loaded.problems.count == 1)
        let problem = try #require(loaded.problems.first)
        #expect(problem.file.lastPathComponent == "bbbbbbbbbbbb.json")
        #expect(problem.message.hasPrefix("corrupt JSON"))
        let backup = try #require(problem.backup)
        #expect(backup.lastPathComponent.hasPrefix("bbbbbbbbbbbb.corrupt-"))
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: store.url(for: badID).path))

        // The backup ends in .json but its stem is not a thread id: ignored on the next load.
        let again = await store.loadAll()
        #expect(again.records == [good])
        #expect(again.problems.isEmpty)
    }

    @Test func unrelatedFilesAreIgnored() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        let good = try makeRecord(id: "aaaaaaaaaaaa", createdAt: 1_800_000_000)
        await store.save(good)
        // "DDDDDDDDDDDD" (not "AAAAAAAAAAAA"): the default macOS file system is case-insensitive,
        // so the uppercase twin of the good record would overwrite it.
        for name in ["README.txt", "notes.json", ".hidden.json", "DDDDDDDDDDDD.json", "aaaaaaaaaaaa.json.bak"] {
            try Data("not a record".utf8).write(to: store.directory.appending(path: name))
        }
        try FileManager.default.createDirectory(at: store.directory.appending(path: "cccccccccccc.json"), withIntermediateDirectories: false)

        let loaded = await store.loadAll()
        #expect(loaded.records == [good])
        // Only the directory named like a record produces a problem (it cannot be read as a file).
        #expect(loaded.problems.map(\.file.lastPathComponent) == ["cccccccccccc.json"])
    }

    @Test func newerSchemaVersionIsRefusedAndNeverOverwritten() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        let id = try #require(ThreadID(rawValue: "dddddddddddd"))
        let original = Data("{ \"version\" : 2, \"id\" : \"dddddddddddd\", \"future\" : true }".utf8)
        try original.write(to: store.url(for: id))

        let loaded = await store.loadAll()
        #expect(loaded.records.isEmpty)
        #expect(loaded.problems.count == 1)
        #expect(loaded.problems.first?.message.contains("schema version 2") == true)
        #expect(loaded.problems.first?.backup == nil)

        await store.save(try makeRecord(id: "dddddddddddd", createdAt: 1_800_000_000))
        #expect(try Data(contentsOf: store.url(for: id)) == original)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(files == ["dddddddddddd.json"])
    }

    @Test func aliveStatesAreNormalizedToIdleAfterRestart() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        let cases: [(String, ThreadState?)] = [
            ("aaaaaaaaaaa1", .running),
            ("aaaaaaaaaaa2", .waiting(reason: .permission)),
            ("aaaaaaaaaaa3", .done),
            ("aaaaaaaaaaa4", .idle),
            ("aaaaaaaaaaa5", .exited),
            ("aaaaaaaaaaa6", nil),
        ]
        for (index, (id, state)) in cases.enumerated() {
            var record = try makeRecord(id: id, createdAt: 1_800_000_000 + TimeInterval(index))
            record.lastState = state
            await store.save(record)
        }

        let loaded = await store.loadAll()
        #expect(loaded.records.map(\.lastState) == [.idle, .idle, .idle, .idle, .exited, nil])
    }

    @Test func idMismatchIsReportedNotQuarantined() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        let record = try makeRecord(id: "bbbbbbbbbbbb", createdAt: 1_800_000_000)
        let wrongName = store.url(for: try #require(ThreadID(rawValue: "aaaaaaaaaaaa")))
        try JSONStore.save(record, to: wrongName, fractionalSeconds: true)

        let loaded = await store.loadAll()
        #expect(loaded.records.isEmpty)
        #expect(loaded.problems.count == 1)
        #expect(loaded.problems.first?.message.contains("does not match") == true)
        #expect(FileManager.default.fileExists(atPath: wrongName.path))
    }

    @Test func partialAndLegacyDocumentsDecode() async throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ThreadRecordStore(home: home)
        let id = try #require(ThreadID(rawValue: "3f9a2c17be04"))
        let json = """
        {
          "version" : 1,
          "id" : "3f9a2c17be04",
          "scopeID" : "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10",
          "driverID" : "shell",
          "title" : "Shell · acme",
          "cwd" : "/Users/me/contributions/acme",
          "cwdKind" : { "scopeRoot" : {} },
          "createdAt" : "2026-09-07T09:13:01.412Z",
          "lastLaunchedAt" : "2026-09-07T11:40:19Z",
          "lastExit" : { "at" : "2026-09-07T10:02:55.130Z", "code" : 0, "signal" : null },
          "launchCount" : 2,
          "resumeID" : null
        }
        """
        try Data(json.utf8).write(to: store.url(for: id))

        let loaded = await store.loadAll()
        #expect(loaded.problems.isEmpty)
        let record = try #require(loaded.records.first)
        #expect(record.id == id)
        #expect(record.scopeID == scopeID)
        #expect(record.scopeRoot == "")            // absent in the legacy document
        #expect(record.cwdKind == .scopeRoot)
        #expect(record.launchCount == 2)
        #expect(record.resumeID == nil)
        #expect(record.lastState == nil)
        #expect(record.log == nil)
        #expect(record.lastExit?.code == 0)
        #expect(record.lastExit?.signal == nil)
        #expect(record.lastExit?.isClean == true)
        #expect(record.lastLaunchedAt == Date(timeIntervalSince1970: 1_788_781_219))
    }
}
