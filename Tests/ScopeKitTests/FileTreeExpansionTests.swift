import Testing
@testable import ScopeCore

@Suite struct FileTreeExpansionTests {
    @Test func startsWithTheRootAlone() {
        #expect(FileTreeExpansion().expanded.isEmpty)
    }

    @Test func ancestorsAreEveryFolderAboveAPath() {
        #expect(FileTreeExpansion.ancestors(of: "a/b/c.swift") == ["a", "a/b"])
        #expect(FileTreeExpansion.ancestors(of: "README.md") == [])
    }

    @Test func revealOpensOnlyTheWayToTheFile() {
        var tree = FileTreeExpansion()
        tree.reveal("Sources/ScopeCore/Slug.swift")
        #expect(tree.expanded == ["Sources", "Sources/ScopeCore"])
        #expect(!tree.isExpanded("Sources/ScopeCore/Slug.swift"))
    }

    @Test func toggleOpensAndCloses() {
        var tree = FileTreeExpansion()
        tree.toggle("docs")
        #expect(tree.isExpanded("docs"))
        tree.toggle("docs")
        #expect(!tree.isExpanded("docs"))
    }

    @Test func collapseAllClosesEverything() {
        var tree = FileTreeExpansion()
        tree.reveal("a/b/c/d.txt")
        tree.collapseAll()
        #expect(tree.expanded.isEmpty)
    }
}
