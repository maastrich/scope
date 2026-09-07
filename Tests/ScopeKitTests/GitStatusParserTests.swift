import Foundation
import Testing
@testable import ScopeGit

/// Builds `-z` output: every record NUL-terminated, exactly what git writes.
private func porcelain(_ records: [String]) -> Data {
    var data = Data()
    for record in records {
        data.append(contentsOf: Array(record.utf8))
        data.append(0)
    }
    return data
}

@Suite struct GitStatusParserTests {
    @Test func branchHeaderWithAheadBehind() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +1 -2",
        ]))
        #expect(status.head == .branch("main"))
        #expect(status.branchName == "main")
        #expect(status.oid == "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 1)
        #expect(status.behind == 2)
        #expect(status.entries.isEmpty)
        #expect(!status.isDirty)
        #expect(!status.isDetached)
    }

    @Test func noUpstreamMeansZeroAheadBehind() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head feature",
        ]))
        #expect(status.upstream == nil)
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
        #expect(status.branchName == "feature")
    }

    @Test func detachedHead() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head (detached)",
        ]))
        #expect(status.head == .detached)
        #expect(status.isDetached)
        #expect(status.branchName == nil)
    }

    @Test func initialCommitIsUnborn() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid (initial)",
            "# branch.head main",
        ]))
        #expect(status.head == .initial)
        #expect(status.oid == nil)
        #expect(status.branchName == nil)
    }

    @Test func emptyOutputIsInitialAndClean() {
        let status = GitStatus(porcelainV2: Data())
        #expect(status.head == .initial)
        #expect(status.entries.isEmpty)
        #expect(!status.isDirty)
    }

    @Test func ordinaryChangedEntries() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head main",
            "1 .M N... 100644 100644 100644 e69de29 e69de29 README.md",
            "1 A. N... 000000 100644 100644 0000000 e69de29 src/new file.swift",
            "1 MM N... 100644 100644 100644 e69de29 abcdef0 both.txt",
        ]))
        #expect(status.entries.count == 3)
        #expect(status.entries[0] == GitStatus.Entry(xy: ".M", path: "README.md"))
        #expect(status.entries[1] == GitStatus.Entry(xy: "A.", path: "src/new file.swift"))
        #expect(status.entries[2].xy == "MM")
        #expect(status.entries[0].isUnstaged && !status.entries[0].isStaged)
        #expect(status.entries[1].isStaged && !status.entries[1].isUnstaged)
        #expect(status.entries[2].isStaged && status.entries[2].isUnstaged)
        #expect(status.isDirty)
        #expect(status.changedCount == 3)
        #expect(!status.hasUntracked)
    }

    @Test func renameWithSpacesCarriesOriginalPath() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head main",
            "2 R. N... 100644 100644 100644 e69de29 e69de29 R100 c d.txt",
            "a b.txt",
            "1 .M N... 100644 100644 100644 e69de29 e69de29 after.txt",
        ]))
        #expect(status.entries.count == 2)
        #expect(status.entries[0] == GitStatus.Entry(xy: "R.", path: "c d.txt", originalPath: "a b.txt"))
        #expect(status.entries[1].path == "after.txt")   // the extra NUL field did not shift the next record
    }

    @Test func untrackedAndIgnored() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head main",
            "? new.txt",
            "? dir with space/file",
            "! build/",
        ]))
        #expect(status.entries.count == 3)
        #expect(status.entries[0] == GitStatus.Entry(xy: "??", path: "new.txt"))
        #expect(status.entries[1].path == "dir with space/file")
        #expect(status.entries[2] == GitStatus.Entry(xy: "!!", path: "build/"))
        #expect(status.entries[0].isUntracked)
        #expect(status.entries[2].isIgnored)
        #expect(status.hasUntracked)
        #expect(status.isDirty)
        #expect(status.changedCount == 2)
    }

    @Test func onlyIgnoredIsClean() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head main",
            "! .build/",
        ]))
        #expect(!status.isDirty)
        #expect(status.changedCount == 0)
    }

    @Test func unmergedEntry() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head main",
            "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict file.txt",
        ]))
        #expect(status.entries.count == 1)
        #expect(status.entries[0] == GitStatus.Entry(xy: "UU", path: "conflict file.txt"))
        #expect(status.entries[0].isUnmerged)
        #expect(!status.entries[0].isStaged)
        #expect(status.hasConflicts)
        #expect(status.isDirty)
    }

    @Test func malformedRecordsAreSkipped() {
        let status = GitStatus(porcelainV2: porcelain([
            "# branch.oid abc",
            "# branch.head main",
            "# nonsense",
            "1 .M",                 // too short
            "x unknown record",
            "2 R. N... 100644 100644 100644 e69de29 e69de29 R100 lonely.txt",   // rename cut before its original-path field
        ]))
        #expect(status.entries.isEmpty)
        #expect(status.branchName == "main")
    }

    @Test func trailingNulDoesNotProduceAnEmptyEntry() {
        var data = porcelain(["# branch.oid abc", "# branch.head main", "? a"])
        data.append(0)   // an extra terminator, as some wrappers add
        let status = GitStatus(porcelainV2: data)
        #expect(status.entries == [GitStatus.Entry(xy: "??", path: "a")])
    }
}
