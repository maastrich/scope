import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeTasks

@Suite struct ViewedMarksTests {
    private static func file(_ path: String, line: String) -> DiffFile {
        DiffFile(path: path, status: .modified, additions: 1, deletions: 0, hunks: [
            DiffHunk(header: "@@ -1 +1 @@", oldStart: 1, oldCount: 0, newStart: 1, newCount: 1,
                     lines: [DiffLine(kind: .addition, text: line, newLineNumber: 1)]),
        ])
    }

    @Test func aMarkStandsWhileTheDiffIsTheOneLookedAt() {
        var marks = ViewedMarks()
        let before = Self.file("a.swift", line: "let a = 1")
        #expect(marks.state(mode: .task, repo: ".", path: "a.swift", digest: DiffDigest.of(before)) == .unviewed)
        let at = Date(timeIntervalSince1970: 1_000)
        marks.set(mode: .task, repo: ".", path: "a.swift", digest: DiffDigest.of(before), at: at)
        #expect(marks.state(mode: .task, repo: ".", path: "a.swift", digest: DiffDigest.of(before)) == .viewed(at: at))
        // Another mode or another repository is another look.
        #expect(marks.state(mode: .uncommitted, repo: ".", path: "a.swift", digest: DiffDigest.of(before)) == .unviewed)
        #expect(marks.state(mode: .task, repo: "api", path: "a.swift", digest: DiffDigest.of(before)) == .unviewed)
    }

    @Test func aTouchedFileIsChangedSinceViewedNotUnviewed() {
        var marks = ViewedMarks()
        let before = Self.file("a.swift", line: "let a = 1")
        let after = Self.file("a.swift", line: "let a = 2")
        let at = Date(timeIntervalSince1970: 1_000)
        marks.set(mode: .task, repo: ".", path: "a.swift", digest: DiffDigest.of(before), at: at)
        let state = marks.state(mode: .task, repo: ".", path: "a.swift", digest: DiffDigest.of(after))
        #expect(state == .changedSinceViewed(at: at))
        #expect(state.isChanged && !state.isViewed)
        // Marking it again is looking at the new diff.
        marks.set(mode: .task, repo: ".", path: "a.swift", digest: DiffDigest.of(after))
        #expect(marks.state(mode: .task, repo: ".", path: "a.swift", digest: DiffDigest.of(after)).isViewed)
        #expect(marks.marks.count == 1)
        marks.clear(mode: .task, repo: ".", path: "a.swift")
        #expect(marks.isEmpty)
    }

    @Test func marksOfFilesGoneFromTheDeltaAreDroppedInTheirModeOnly() {
        var marks = ViewedMarks()
        marks.set(mode: .task, repo: ".", path: "kept.swift", digest: "1")
        marks.set(mode: .task, repo: ".", path: "reverted.swift", digest: "2")
        marks.set(mode: .uncommitted, repo: ".", path: "reverted.swift", digest: "3")
        marks.retain(mode: .task) { $0.path == "kept.swift" }
        #expect(marks.mark(mode: .task, repo: ".", path: "kept.swift") != nil)
        #expect(marks.mark(mode: .task, repo: ".", path: "reverted.swift") == nil)
        #expect(marks.mark(mode: .uncommitted, repo: ".", path: "reverted.swift") != nil)
    }

    @Test func theHeaderCountsViewedAndChanged() {
        var marks = ViewedMarks()
        marks.set(mode: .task, repo: ".", path: "a", digest: "same")
        marks.set(mode: .task, repo: ".", path: "b", digest: "old")
        let counts = marks.counts(mode: .task, files: [(".", "a", "same"), (".", "b", "new"), (".", "c", "x")])
        #expect(counts.viewed == 1)
        #expect(counts.changed == 1)
    }

    @Test func marksAreKeptPerTaskUnderTheHomeAndSurviveARead() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-viewed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ViewedStore(home: home)
        let task = TaskID.generate()
        var marks = ViewedMarks()
        marks.set(mode: .task, repo: "api", path: "a.swift", digest: "abc", at: TaskRecord.roundedToMilliseconds(.now))
        #expect(await store.load(task).isEmpty)
        try await store.save(marks, for: task)
        #expect(store.url(for: task).path.hasPrefix(home.path))
        #expect(await store.load(task) == marks)
        try await store.save(ViewedMarks(), for: task)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: task).path))
    }

    @Test func aFileFromAnotherVersionReadsAsNoMarks() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scope-viewed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = ViewedStore(home: home)
        let task = TaskID.generate()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"version":99,"marks":[]}"#.utf8).write(to: store.url(for: task))
        #expect(await store.load(task).isEmpty)
    }
}
