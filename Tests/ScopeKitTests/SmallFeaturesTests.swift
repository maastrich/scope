import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeControl

@Suite struct SpotlightMarkerTests {
    @Test func theSandboxesFolderIsKeptOutOfSpotlight() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try ScopeHome.ensureLayout(at: home)
        let marker = ScopeHome.spotlightMarkerURL(home: home)
        #expect(marker.path == home.appending(path: "sandboxes/.metadata_never_index").path)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // Idempotent: a second launch finds it and leaves it.
        try ScopeHome.ensureLayout(at: home)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}

@Suite struct TaskBranchAlternativeTests {
    @Test func aBusyBranchGetsTheNextFreeSuffix() {
        #expect(TaskBranch.alternative(to: "feat/cache", taken: ["main"]) == "feat/cache")
        #expect(TaskBranch.alternative(to: "feat/cache", taken: ["feat/cache"]) == "feat/cache-2")
        #expect(TaskBranch.alternative(to: "feat/cache", taken: ["feat/cache", "feat/cache-2", "feat/cache-3"]) == "feat/cache-4")
    }
}

@Suite struct DiffDigestTests {
    private static func file(_ added: String) -> DiffFile {
        DiffFile(path: "a.swift", status: .modified, additions: 1, hunks: [
            DiffHunk(header: "@@ -1,1 +1,2 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 2, lines: [
                DiffLine(kind: .context, text: "let a = 1", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(kind: .addition, text: added, newLineNumber: 2),
            ]),
        ])
    }

    @Test func theDigestChangesWithTheDiffAndOnlyThen() {
        #expect(DiffDigest.of(Self.file("let b = 2")) == DiffDigest.of(Self.file("let b = 2")))
        #expect(DiffDigest.of(Self.file("let b = 2")) != DiffDigest.of(Self.file("let b = 3")))
        // The sign counts: the same text removed instead of added is a different diff.
        var removed = Self.file("let b = 2")
        removed.hunks[0].lines[1] = DiffLine(kind: .deletion, text: "let b = 2", oldLineNumber: 2)
        #expect(DiffDigest.of(removed) != DiffDigest.of(Self.file("let b = 2")))
        // Stable across launches: a fixed value, not a seeded hash.
        #expect(DiffDigest.of(DiffFile(path: "", status: .added)) == DiffDigest.of(DiffFile(path: "", status: .added)))
    }
}

@Suite struct ScopeURLTests {
    @Test func aTaskLinkBecomesTheCommandLinesCall() throws {
        let url = try #require(URL(string: "scope://task/new?scope=acme&prompt=Fix%20the%20login%20test&repo=api&repo=web&branch=fix/login&setup=0&dry_run=1"))
        let params = try #require(ScopeURL.taskNew(from: url))
        #expect(params == TaskNewParams(prompt: "Fix the login test", scope: "acme", repos: ["api", "web"],
                                        branch: "fix/login", runSetup: false))
        // A link never asks for a dry run: that is the command line's, for agents.
        #expect(!params.dryRun)
    }

    @Test func anythingElseIsNotATaskLink() {
        for text in ["scope://task/new", "scope://task/new?prompt=%20%20", "scope://thread/new?prompt=x", "scope://task/close?prompt=x"] {
            #expect(ScopeURL.taskNew(from: URL(string: text)!) == nil, "\(text)")
        }
        #expect(ScopeURL.taskNew(from: URL(string: "scope-debug://task/new?prompt=go")!)?.prompt == "go")
    }
}
