import Testing
@testable import ScopeGraph

@Suite struct TagMergeTests {
    /// The duplicate the user saw on every card: stack chips `node`, `make` and hashtags `#node #make`.
    @Test func stackAndTagsBecomeOneRowSaidOnce() {
        let merged = TagMerge.merge(stack: ["node", "make"], tags: ["node", "#Make", "monorepo"])
        #expect(merged.map(\.label) == ["node", "make", "monorepo"])
        #expect(merged.map(\.isStack) == [true, true, false])
    }

    @Test func comparisonIgnoresCaseHashSeparatorsAndKnownAliases() {
        #expect(TagMerge.normalize("#GitHub Actions") == "github-actions")
        #expect(TagMerge.normalize("github_actions") == "github-actions")
        #expect(TagMerge.normalize("Node.js") == "node")
        #expect(TagMerge.normalize("nodejs") == "node")
        #expect(TagMerge.normalize("docker compose") == "docker-compose")
        #expect(TagMerge.normalize("TS") == "typescript")
        let merged = TagMerge.merge(stack: ["github actions", "node.js", "docker"], tags: ["github-actions", "node", "ci", "script:dev", "", "#"])
        #expect(merged.map(\.label) == ["github actions", "node.js", "docker", "ci"])
    }

    @Test func overflowKeepsOneRowAndCapsAtSix() {
        // Chips of 40, 4 apart, a 30-wide "+N": six chips and the "+N" take 40·6 + 4·6 + 30 = 294 of 300; the cap stops there.
        let widths = Array(repeating: 40.0, count: 9)
        #expect(TagOverflow.visibleCount(widths: widths, available: 300, spacing: 4, moreWidth: 30) == 6)
        #expect(TagOverflow.visibleCount(widths: widths, available: 200, spacing: 4, moreWidth: 30) == 3)
        // Everything fits and no "+N" is needed: the last chip does not reserve room for one.
        #expect(TagOverflow.visibleCount(widths: [40, 40, 40], available: 128, spacing: 4, moreWidth: 30) == 3)
        // The cap holds even with room to spare.
        #expect(TagOverflow.visibleCount(widths: widths, available: 2000, spacing: 4, moreWidth: 30, cap: 6) == 6)
        // One chip too wide for the row still shows (it truncates), never a lone "+1".
        #expect(TagOverflow.visibleCount(widths: [500, 40], available: 200, spacing: 4, moreWidth: 30) == 1)
        #expect(TagOverflow.visibleCount(widths: [], available: 200, spacing: 4, moreWidth: 30) == 0)
    }
}
