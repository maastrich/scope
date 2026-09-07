import Foundation
import Testing
@testable import ScopeGit

@Suite struct DiffParserTests {
    @Test func emptyInputYieldsNoFile() {
        #expect(DiffParser.parse("").isEmpty)
        #expect(DiffParser.parse("\n").isEmpty)
    }

    @Test func modifiedFileWithLineNumbers() {
        let text = """
        diff --git a/src/app.swift b/src/app.swift
        index 1234567..89abcde 100644
        --- a/src/app.swift
        +++ b/src/app.swift
        @@ -1,4 +1,5 @@ func main() {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         print(a)
         
        """
        let files = DiffParser.parse(text)
        #expect(files.count == 1)
        let file = files[0]
        #expect(file.path == "src/app.swift")
        #expect(file.oldPath == nil)
        #expect(file.status == .modified)
        #expect(file.additions == 2)
        #expect(file.deletions == 1)
        #expect(file.hunks.count == 1)
        let hunk = file.hunks[0]
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (1, 4, 1, 5))
        #expect(hunk.context == "func main() {")
        #expect(hunk.lines.count == 6)
        #expect(hunk.lines[0] == DiffLine(kind: .context, text: "let a = 1", oldLineNumber: 1, newLineNumber: 1))
        #expect(hunk.lines[1] == DiffLine(kind: .deletion, text: "let b = 2", oldLineNumber: 2))
        #expect(hunk.lines[2] == DiffLine(kind: .addition, text: "let b = 3", newLineNumber: 2))
        #expect(hunk.lines[3] == DiffLine(kind: .addition, text: "let c = 4", newLineNumber: 3))
        #expect(hunk.lines[4] == DiffLine(kind: .context, text: "print(a)", oldLineNumber: 3, newLineNumber: 4))
        #expect(hunk.lines[5].kind == .context && hunk.lines[5].text == "")
    }

    @Test func addedAndDeletedFiles() {
        let text = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..d95f3ad
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index d95f3ad..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """
        let files = DiffParser.parse(text)
        #expect(files.map(\.path) == ["new.txt", "old.txt"])
        #expect(files[0].status == .added)
        #expect(files[0].additions == 2 && files[0].deletions == 0)
        #expect(files[0].hunks[0].lines.map(\.newLineNumber) == [1, 2])
        #expect(files[1].status == .deleted)
        #expect(files[1].additions == 0 && files[1].deletions == 1)
        #expect(files[1].hunks[0].oldCount == 1 && files[1].hunks[0].newCount == 0)
    }

    @Test func renameWithAndWithoutHunks() {
        let text = """
        diff --git a/a.txt b/b.txt
        similarity index 100%
        rename from a.txt
        rename to b.txt
        diff --git a/lib/x.rb b/lib/y.rb
        similarity index 90%
        rename from lib/x.rb
        rename to lib/y.rb
        index 1111111..2222222 100644
        --- a/lib/x.rb
        +++ b/lib/y.rb
        @@ -1,2 +1,2 @@
         a
        -b
        +c
        """
        let files = DiffParser.parse(text)
        #expect(files.count == 2)
        #expect(files[0].path == "b.txt" && files[0].oldPath == "a.txt" && files[0].status == .renamed)
        #expect(files[0].hunks.isEmpty)
        #expect(files[1].path == "lib/y.rb" && files[1].oldPath == "lib/x.rb" && files[1].status == .renamed)
        #expect(files[1].additions == 1 && files[1].deletions == 1)
    }

    @Test func binaryFile() {
        let text = """
        diff --git a/img.png b/img.png
        new file mode 100644
        index 0000000..abcdef0
        Binary files /dev/null and b/img.png differ
        """
        let files = DiffParser.parse(text)
        #expect(files.count == 1)
        #expect(files[0].path == "img.png")
        #expect(files[0].status == .binary)
        #expect(files[0].isBinary && !files[0].hasHunks)
    }

    @Test func noNewlineMarker() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1 +1 @@
        -one
        \\ No newline at end of file
        +one
        """
        let file = DiffParser.parse(text)[0]
        let lines = file.hunks[0].lines
        #expect(lines.map(\.kind) == [.deletion, .noNewline, .addition])
        #expect(lines[1].text == "No newline at end of file")
        #expect(lines[1].oldLineNumber == nil && lines[1].newLineNumber == nil)
        #expect(lines[2].newLineNumber == 1)
    }

    @Test func contentLinesThatLookLikeHeadersStayContent() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,3 @@
         --- not a header
        +++++ four pluses
         +++ b/neither
        """
        let file = DiffParser.parse(text)[0]
        #expect(file.hunks[0].lines.map(\.text) == ["--- not a header", "++++ four pluses", "+++ b/neither"])
        #expect(file.additions == 1)
    }

    @Test func multipleHunks() {
        let text = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c
        @@ -10,3 +10,4 @@ ctx
         x
        +y
         z
         w
        """
        let file = DiffParser.parse(text)[0]
        #expect(file.hunks.count == 2)
        #expect(file.hunks[1].newStart == 10)
        #expect(file.hunks[1].lines[1] == DiffLine(kind: .addition, text: "y", newLineNumber: 11))
        #expect(file.additions == 2 && file.deletions == 1)
    }

    @Test func numstatParsingAndMerge() {
        var data = Data()
        data.append(contentsOf: "3\t1\tsrc/a.swift\0".utf8)
        data.append(contentsOf: "-\t-\timg.png\0".utf8)
        data.append(contentsOf: "0\t0\t\0old/name.rb\0new/name.rb\0".utf8)
        let stats = DiffParser.parseNumstat(data)
        #expect(stats["src/a.swift"] == DiffParser.NumstatEntry(additions: 3, deletions: 1))
        #expect(stats["img.png"] == DiffParser.NumstatEntry(additions: nil, deletions: nil))
        #expect(stats["new/name.rb"] == DiffParser.NumstatEntry(additions: 0, deletions: 0, oldPath: "old/name.rb"))

        let merged = DiffParser.merge(
            [DiffFile(path: "src/a.swift", status: .modified, additions: 1, deletions: 1),
             DiffFile(path: "img.png", status: .binary)],
            numstat: stats
        )
        #expect(merged[0].additions == 3 && merged[0].deletions == 1)
        #expect(merged[1].additions == 0 && merged[1].deletions == 0)   // nil counts keep the parsed value
        #expect(DiffSummary(merged) == DiffSummary(files: 2, additions: 3, deletions: 1))
    }

    @Test func pathsWithSpacesFromGitHeader() {
        let text = """
        diff --git a/my file.txt b/my file.txt
        index 1..2 100644
        --- a/my file.txt\t
        +++ b/my file.txt\t
        @@ -1 +1 @@
        -a
        +b
        """
        let file = DiffParser.parse(text)[0]
        #expect(file.path == "my file.txt")
        #expect(DiffParser.samePath(fromGitHeader: "a/my file.txt b/my file.txt") == "my file.txt")
        #expect(DiffParser.samePath(fromGitHeader: "a/x b/y") == nil)
    }
}
