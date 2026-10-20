import Foundation
import Testing
import ScopeAdapters
import ScopeCore
@testable import ScopeTasks

@Suite struct TaskArtifactsTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    static let scopeID = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")

    /// A task of two repositories: sandboxes under `/tasks/x/api` and `/tasks/x/web`, root `/tasks/x`.
    static func multiRepo(deliverable: String? = nil) -> TaskRecord {
        TaskRecord(scopeID: scopeID, scopeRoot: "/acme", scopeSlug: "acme", name: "X", slug: "x", branch: "feat/x", root: "/tasks/x",
                   repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/tasks/x/api", branch: "feat/x"),
                           TaskRepo(repoRelativePath: "web", sandboxPath: "/tasks/x/web", branch: "feat/x")],
                   deliverable: deliverable)
    }

    /// A task of one repository: the sandbox is `/tasks/y/app`, where its threads start.
    static func monoRepo() -> TaskRecord {
        TaskRecord(scopeID: scopeID, scopeRoot: "/acme", scopeSlug: "acme", name: "Y", slug: "y", branch: "feat/y", root: "/tasks/y",
                   repos: [TaskRepo(repoRelativePath: "app", sandboxPath: "/tasks/y/app", branch: "feat/y")])
    }

    static func call(_ name: String, _ target: String?, at seconds: TimeInterval) -> ThreadActivity.Tool {
        .init(name: name, target: target, at: at(seconds))
    }

    static func turn(_ start: TimeInterval, _ end: TimeInterval, said: String? = nil, calls: [ThreadActivity.Tool] = []) -> ThreadActivity.Turn {
        .init(startedAt: at(start), endedAt: at(end), outcome: .ended, tools: calls.count, said: said, calls: calls.isEmpty ? nil : calls)
    }

    static func thread(_ id: String, turns: [ThreadActivity.Turn], open: [ThreadActivity.Tool] = [], reply: AgentReply? = nil) -> TaskArtifacts.Thread {
        var activity = ThreadActivity(turns: turns, lastReply: reply)
        if !open.isEmpty {
            activity.turnStartedAt = at(1000)
            activity.turnCalls = open
        }
        return .init(id: id, title: "Thread \(id)", activity: activity)
    }

    // MARK: Written files

    @Test func writesOfEveryTurnAndTheOpenOneNewestFirstOnePerPath() {
        let threads = [
            Self.thread("a", turns: [
                Self.turn(0, 10, calls: [Self.call("Write", "/tmp/one.txt", at: 2), Self.call("Read", "/tmp/read.txt", at: 3)]),
                Self.turn(20, 30, calls: [Self.call("Edit", "/tmp/one.txt", at: 25), Self.call("Write", "/tmp/two.png", at: 26)]),
            ], open: [Self.call("NotebookEdit", "/tmp/nb.ipynb", at: 1001)]),
            Self.thread("b", turns: [Self.turn(5, 15, calls: [Self.call("Write", "/tmp/b.md", at: 12)])]),
        ]
        let writes = TaskArtifacts.writtenCandidates(threads: threads, cwd: "/tasks/y/app")
        #expect(writes.map(\.path) == ["/tmp/nb.ipynb", "/tmp/two.png", "/tmp/one.txt", "/tmp/b.md"])
        #expect(writes.map(\.turn) == [3, 2, 2, 1])
        #expect(writes.map(\.threadID) == ["a", "a", "a", "b"])
        // The second write of one.txt is the one kept: an Edit at turn 2.
        #expect(writes[2].tool == "Edit")
    }

    @Test func relativeTargetsResolveFromTheCwdAndCutOnesAreDropped() {
        let threads = [Self.thread("a", turns: [Self.turn(0, 10, calls: [
            Self.call("Write", "docs/notes.md", at: 1),
            Self.call("Write", "/very/long/path/that/the/adapter/cut/at/one/hundred/and/twenty/chara…", at: 2),
            Self.call("Write", nil, at: 3),
        ])])]
        let writes = TaskArtifacts.writtenCandidates(threads: threads, cwd: "/tasks/y/app")
        #expect(writes.map(\.path) == ["/tasks/y/app/docs/notes.md"])
    }

    @Test func bashRedirectionsAreWritesAndDescriptorsAreNot() {
        #expect(TaskArtifacts.redirections(in: "echo hi > /tmp/out.txt") == ["/tmp/out.txt"])
        #expect(TaskArtifacts.redirections(in: "make 2>&1 | tee build.log >> logs/all.log") == ["logs/all.log"])
        #expect(TaskArtifacts.redirections(in: "cmd > \"/tmp/with space.txt\"; other >'q.txt'") == ["/tmp/with space.txt", "q.txt"])
        #expect(TaskArtifacts.redirections(in: "cmd > /dev/null 2>&1 &> /dev/null") == [])
        #expect(TaskArtifacts.redirections(in: "diff <(a) >(b)") == [])
        #expect(TaskArtifacts.redirections(in: "cmd > $OUT") == [])
        let threads = [Self.thread("a", turns: [Self.turn(0, 10, calls: [Self.call("Bash", "swift build > build.log", at: 1)])])]
        let writes = TaskArtifacts.writtenCandidates(threads: threads, cwd: "/tasks/y/app")
        #expect(writes.map(\.path) == ["/tasks/y/app/build.log"])
        #expect(writes[0].tool == "Bash")
    }

    @Test func placementTellsTheDiffFromTheRest() {
        let sandboxes = Self.multiRepo().activeSandboxes
        let ignored: (String) -> Bool = { $0.hasPrefix("/tasks/x/api/node_modules/") || $0.hasSuffix(".log") }
        #expect(TaskArtifacts.placement(of: "/tasks/x/api/src/a.ts", sandboxes: sandboxes, isIgnored: ignored) == nil)
        #expect(TaskArtifacts.placement(of: "/tasks/x/api/node_modules/x/i.js", sandboxes: sandboxes, isIgnored: ignored) == .ignored)
        #expect(TaskArtifacts.placement(of: "/tasks/x/web/out.log", sandboxes: sandboxes, isIgnored: ignored) == .ignored)
        #expect(TaskArtifacts.placement(of: "/tasks/x/web/.git/info/exclude", sandboxes: sandboxes, isIgnored: ignored) == .ignored)
        #expect(TaskArtifacts.placement(of: "/tasks/x/web/shots/a.png", sandboxes: sandboxes, isIgnored: ignored) == .binary)
        #expect(TaskArtifacts.placement(of: "/tasks/x/api/docs/spec.PDF", sandboxes: sandboxes, isIgnored: ignored) == .binary)
        #expect(TaskArtifacts.placement(of: "/tasks/x/REPORT.md", sandboxes: sandboxes, isIgnored: ignored) == .outsideSandboxes)
        #expect(TaskArtifacts.placement(of: "/tmp/scratch.txt", sandboxes: sandboxes, isIgnored: ignored) == .outsideSandboxes)
        // A sibling folder whose name starts like a sandbox is not inside it.
        #expect(TaskArtifacts.placement(of: "/tasks/x/api-old/a.ts", sandboxes: sandboxes, isIgnored: ignored) == .outsideSandboxes)
    }

    @Test func rowsAreNamedFromTheirSandboxOrTheRoot() {
        let multi = Self.multiRepo()
        #expect(TaskArtifacts.displayName(of: "/tasks/x/api/node_modules/i.js", record: multi) == "api/node_modules/i.js")
        #expect(TaskArtifacts.displayName(of: "/tasks/x/notes.md", record: multi) == "notes.md")
        #expect(TaskArtifacts.displayName(of: "/tmp/a.txt", record: multi) == "/tmp/a.txt")
        #expect(TaskArtifacts.displayName(of: NSHomeDirectory() + "/Desktop/a.png", record: multi) == "~/Desktop/a.png")
        let mono = Self.monoRepo()
        #expect(TaskArtifacts.displayName(of: "/tasks/y/app/shots/a.png", record: mono) == "shots/a.png")
    }

    // MARK: Published pages

    @Test func linksAreExtractedWithoutTheirPunctuation() {
        let text = """
        Published https://claude.ai/artifact/abc123. See (https://github.com/o/r/pull/12), and
        [the docs](https://example.com/docs/page?x=1#top). Plain http://insecure.example is not kept; <https://a.b/c> is.
        A cut one https://github.com/o/r/pull/… stays out, so does `https://` alone.
        """
        #expect(TaskArtifacts.links(in: text) == [
            "https://claude.ai/artifact/abc123", "https://github.com/o/r/pull/12",
            "https://example.com/docs/page?x=1#top", "https://a.b/c",
        ])
    }

    @Test func pagesAreClassifiedDedupedAndNewestFirst() {
        let reply = AgentReply(text: "Done. Opened https://github.com/o/r/pull/12 and https://claude.ai/artifact/abc123def and https://example.com/x/y/", at: Self.at(55))
        let threads = [
            Self.thread("a", turns: [
                Self.turn(0, 10, said: "See https://claude.ai/artifact/abc123def"),
                Self.turn(20, 30, said: "Issue at https://github.com/o/r/issues/7, commit https://github.com/o/r/commit/0123456789abcdef"),
                Self.turn(50, 60),
            ], reply: reply),
        ]
        let pages = TaskArtifacts.pages(from: TaskArtifacts.mentions(threads: threads))
        #expect(pages.map(\.url) == [
            "https://github.com/o/r/pull/12", "https://claude.ai/artifact/abc123def", "https://example.com/x/y/",
            "https://github.com/o/r/issues/7", "https://github.com/o/r/commit/0123456789abcdef",
        ])
        #expect(pages.map(\.kind) == [.pullRequest, .artifact, .other, .issue, .commit])
        #expect(pages.map(\.title) == ["Pull request #12 · o/r", "Artifact abc123de", "example.com · y", "Issue #7 · o/r", "Commit 0123456 · o/r"])
        #expect(pages.map(\.turn) == [3, 3, 3, 2, 2], "the reply belongs to the turn that ended at its time")
        #expect(pages.map(\.host) == ["github.com", "claude.ai", "example.com", "github.com", "github.com"])
    }

    @Test func aReplyWithNoClosedTurnBelongsToTheOpenOne() {
        var activity = ThreadActivity(lastReply: AgentReply(text: "https://example.com/a", at: Self.at(5)))
        activity.turnStartedAt = Self.at(1)
        let pages = TaskArtifacts.pages(from: TaskArtifacts.mentions(threads: [.init(id: "a", title: "A", activity: activity)]))
        #expect(pages.map(\.turn) == [1])
    }

    // MARK: Report

    @Test func theDeclaredFileComesBeforeReportMdAndEveryFolderIsLookedIn() {
        let record = Self.multiRepo(deliverable: "docs/study.md")
        let candidates = TaskArtifacts.reportCandidates(record: record)
        #expect(candidates.map(\.path) == [
            "/tasks/x/docs/study.md", "/tasks/x/api/docs/study.md", "/tasks/x/web/docs/study.md",
            "/tasks/x/REPORT.md", "/tasks/x/api/REPORT.md", "/tasks/x/web/REPORT.md",
        ])
        #expect(candidates.map(\.name) == ["docs/study.md", "api/docs/study.md", "web/docs/study.md", "REPORT.md", "api/REPORT.md", "web/REPORT.md"])
        #expect(candidates.map(\.isDeclared) == [true, true, true, false, false, false])
        // A name that climbs out of the task is never looked for.
        let climbing = TaskArtifacts.reportCandidates(record: Self.multiRepo(deliverable: "../secrets.md"))
        #expect(climbing.map(\.name) == ["REPORT.md", "api/REPORT.md", "web/REPORT.md"])
        // One repository: the sandbox is the thread cwd, no label.
        #expect(TaskArtifacts.reportCandidates(record: Self.monoRepo()).map(\.name) == ["REPORT.md", "REPORT.md"])
    }

    // MARK: Assembly

    @Test func collectFoldsEverythingAndFlagsGoneFiles() {
        let record = Self.monoRepo()
        let threads = [Self.thread("a", turns: [
            Self.turn(0, 10, said: "Wrote https://claude.ai/artifact/zzz", calls: [
                Self.call("Write", "/tasks/y/app/REPORT.md", at: 1),
                Self.call("Write", "/tasks/y/app/src/main.swift", at: 2),
                Self.call("Write", "/tmp/scratch/notes.md", at: 3),
                Self.call("Write", "/tasks/y/app/shots/a.png", at: 4),
                Self.call("Write", "/tasks/y/app/.build/x.o", at: 5),
            ]),
        ])]
        let checkpoints = [TaskCheckpoint(number: 1, at: Self.at(10), repos: [])]
        let facts: [String: TaskArtifacts.FileFacts] = [
            "/tasks/y/app/REPORT.md": .init(bytes: 1200, modifiedAt: Self.at(9)),
            "/tasks/y/app/src/main.swift": .init(bytes: 10),
            "/tasks/y/app/shots/a.png": .init(bytes: 50_000),
            "/tasks/y/app/.build/x.o": .init(bytes: 7),
        ]
        let artifacts = TaskArtifacts.collect(record: record, threads: threads, checkpoints: checkpoints,
                                              facts: { facts[$0] }, isIgnored: { $0.contains("/.build/") }, reportAdditions: 71)
        #expect(artifacts.report == .init(path: "/tasks/y/app/REPORT.md", name: "REPORT.md", isDeclared: false, bytes: 1200,
                                          modifiedAt: Self.at(9), additions: 71))
        #expect(artifacts.files.map(\.name) == [".build/x.o", "shots/a.png", "/tmp/scratch/notes.md"])
        #expect(artifacts.files.map(\.placement) == [.ignored, .binary, .outsideSandboxes])
        #expect(artifacts.files.map(\.exists) == [true, true, false])
        #expect(artifacts.newestImage?.name == "shots/a.png")
        #expect(artifacts.pages.map(\.kind) == [.artifact])
        #expect(artifacts.checkpoints.count == 1)
        #expect(artifacts.summary == "REPORT.md · 3 files · 1 page")
    }

    @Test func summaryFallsBackToCheckpointsThenNothing() {
        #expect(TaskArtifacts.empty.summary == "nothing yet")
        #expect(TaskArtifacts.empty.isEmpty)
        let checkpoints = TaskArtifacts(checkpoints: [TaskCheckpoint(number: 1, at: Self.t0, repos: []),
                                                      TaskCheckpoint(number: 2, at: Self.t0, repos: [])])
        #expect(checkpoints.summary == "2 checkpoints")
        #expect(checkpoints.producedNothing && !checkpoints.isEmpty)
        let one = TaskArtifacts(files: [.init(path: "/tmp/a", name: "/tmp/a", placement: .outsideSandboxes, tool: "Write",
                                              threadID: "a", threadTitle: "A", turn: 1, at: Self.t0)],
                                pages: [.init(url: "https://x.y", kind: .other, title: "x.y", host: "x.y", threadID: "a", turn: 1, at: Self.t0)],
                                checkpoints: [TaskCheckpoint(number: 1, at: Self.t0, repos: [])])
        #expect(one.summary == "1 file · 1 page", "checkpoints stay out of the line once something was produced")
    }

    @Test func aMissingReportLeavesTheReportOut() {
        let artifacts = TaskArtifacts.collect(record: Self.monoRepo(), threads: [], checkpoints: [], facts: { _ in nil }, isIgnored: { _ in false })
        #expect(artifacts.report == nil)
        #expect(artifacts.isEmpty)
    }
}
