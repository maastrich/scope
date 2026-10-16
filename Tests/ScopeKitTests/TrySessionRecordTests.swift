import Foundation
import Testing
import ScopeCore
@testable import ScopeTasks

/// The try session on a task record (spec §4.5): written, read back, looked up by repository, and absent from
/// records written before it existed.
@Suite struct TrySessionRecordTests {
    private func record() -> TaskRecord {
        TaskRecord(scopeID: ScopeID(rawValue: "acme"), scopeRoot: "/tmp/acme", scopeSlug: "acme", name: "Auth cache", slug: "auth-cache",
                   branch: "feat/auth-cache", root: "/tmp/home/sandboxes/acme/auth-cache",
                   repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/tmp/sb/api", branch: "feat/auth-cache")])
    }

    @Test func aSessionSurvivesTheRecordRoundTrip() throws {
        var task = record()
        let since = Date(timeIntervalSince1970: 1_760_000_000.123)
        task.trying = [TrySession(repoRelativePath: "./api/", previousHead: "abc123", previousBranch: "main", stashSHA: "def456",
                                  head: "fed987", since: since)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TaskRecord.self, from: try encoder.encode(task))
        #expect(back.trying.count == 1)
        let session = try #require(back.trySession(for: "api"))
        #expect(session.repoRelativePath == "api" && session.previousBranch == "main" && session.stashSHA == "def456")
        #expect(session.previousLabel == "main" && !session.isEnding)
        #expect(back.trySession(for: "web") == nil)
    }

    @Test func aDetachedBaseIsNamedByItsCommit() {
        let session = TrySession(repoRelativePath: ".", previousHead: "0123456789abcdef", previousBranch: nil, stashSHA: nil, head: "x",
                                 endingAt: .now)
        #expect(session.previousLabel == "0123456")
        #expect(session.isEnding)
    }

    @Test func anOlderRecordHasNoSession() throws {
        let task = record()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "trying")
        let back = try JSONDecoder().decode(TaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.trying.isEmpty)
    }
}
