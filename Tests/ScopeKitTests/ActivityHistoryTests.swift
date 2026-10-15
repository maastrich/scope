import Foundation
import ScopeCore
import ScopeTasks
import Testing

/// Closing a task or a thread deletes its record; the history keeps the line that says it existed.
@Suite struct ActivityHistoryTests {
    static func temporaryHome() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "scope-history-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    }

    @Test func deletingAThreadRecordLeavesItsSnapshot() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try ScopeHome.ensureLayout(at: home)
        let store = ThreadRecordStore(home: home)
        var record = ThreadRecord(scopeID: ScopeID(rawValue: "S1"), scopeRoot: "/work/acme", driverID: "claude-code",
                                  title: "look at CI", cwd: "/work/acme", cwdKind: .scopeRoot,
                                  createdAt: Date(timeIntervalSince1970: 1_760_000_000.25))
        record.resumeID = "session-1"
        record.launchCount = 2
        await store.save(record)

        await store.delete(record.id)

        let history = ActivityHistory.load(home: home)
        #expect(history.count == 1)
        #expect(history[0].kind == .threadClosed)
        #expect(history[0].thread == record.snapshot)
        #expect(history[0].thread?.session == "session-1")
        await store.delete(record.id)
        #expect(ActivityHistory.load(home: home).count == 1, "deleting what is already gone writes nothing")
    }

    @Test func deletingATaskRecordLeavesItsSnapshotWithTheBriefCapped() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TaskRecordStore(home: home)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let prompt = String(repeating: "x", count: TaskSnapshot.promptLimit + 500)
        let record = TaskRecord(scopeID: ScopeID(rawValue: "S1"), scopeRoot: "/work/acme", scopeSlug: "acme", name: "Spike",
                                slug: "spike", branch: "spike/parser", root: "/home/sandboxes/acme/spike",
                                pullRequest: LinkedPullRequest(number: 7, url: URL(string: "https://github.com/acme/api/pull/7")!,
                                                               title: "Parser spike", state: "closed"),
                                prompt: prompt, topic: "parser")
        try await store.save(record)

        try await store.delete(record.id)

        let history = ActivityHistory.load(home: home)
        #expect(history.map(\.kind) == [.taskClosed])
        let snapshot = try #require(history[0].task)
        #expect(snapshot.slug == "spike")
        #expect(snapshot.topic == "parser")
        #expect(snapshot.pullRequest?.state == "closed")
        #expect(snapshot.prompt?.count == TaskSnapshot.promptLimit + 1)
    }

    @Test func aLineThatDoesNotDecodeIsSkipped() throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let thread = ThreadSnapshot(id: "aaaaaaaaaaaa", title: "t", driverID: "shell", scopeID: "S1", scopeRoot: "/w",
                                    createdAt: Date(timeIntervalSince1970: 1_000))
        ActivityHistory.append(.threadClosed(thread, at: Date(timeIntervalSince1970: 2_000)), home: home)
        let handle = try FileHandle(forWritingTo: ActivityHistory.url(home: home))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"kind\":\"task.clo".utf8))
        try handle.close()
        ActivityHistory.append(.threadClosed(thread, at: Date(timeIntervalSince1970: 3_000)), home: home)

        let history = ActivityHistory.load(home: home)
        #expect(history.map(\.at) == [Date(timeIntervalSince1970: 2_000), Date(timeIntervalSince1970: 3_000)],
                "the line after the cut one starts on its own")
        #expect(history.first?.thread == thread)
    }

    @Test func aPullRequestLinkRemembersTheStateItWasLastSeenIn() throws {
        let link = LinkedPullRequest(number: 3, url: URL(string: "https://github.com/acme/api/pull/3")!, title: "x", state: "merged")
        let decoded = try JSONDecoder().decode(LinkedPullRequest.self, from: JSONEncoder().encode(link))
        #expect(decoded.state == "merged")
        let older = Data(#"{"number":3,"url":"https://github.com/acme/api/pull/3","title":"x","isCrossRepository":false}"#.utf8)
        #expect(try JSONDecoder().decode(LinkedPullRequest.self, from: older).state == nil)
    }
}
