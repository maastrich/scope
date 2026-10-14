import Testing
@testable import ScopeCore

@Suite struct FileLinkResolverTests {
    private let roots = [
        FileLinkResolver.Root(name: "hashup", sandbox: "/sb/task/hashup", base: "/work/hashup"),
        FileLinkResolver.Root(name: "gh-next", sandbox: "/sb/task/gh-next", base: "/work/gh-next"),
    ]

    private func resolve(_ link: String, from directory: String? = nil, roots: [FileLinkResolver.Root]? = nil,
                         existing: Set<String>) -> FileLinkResolver.Resolution? {
        FileLinkResolver.resolve(link, threadDirectory: directory, roots: roots ?? self.roots) { existing.contains($0) }
    }

    @Test func parsesLineAndColumn() {
        #expect(FileLinkResolver.parse("src/a.ts:12")! == ("src/a.ts", 12, nil))
        #expect(FileLinkResolver.parse("src/a.ts:12:4")! == ("src/a.ts", 12, 4))
        #expect(FileLinkResolver.parse("src/a.ts")! == ("src/a.ts", nil, nil))
    }

    @Test func parsesFileURLsAndStripsSentencePunctuation() {
        #expect(FileLinkResolver.parse("file:///sb/task/hashup/a%20b.ts")! == ("/sb/task/hashup/a b.ts", nil, nil))
        #expect(FileLinkResolver.parse("file:///x/a.ts#L7")! == ("/x/a.ts", 7, nil))
        #expect(FileLinkResolver.parse("(src/a.ts:3).")! == ("src/a.ts", 3, nil))
    }

    @Test func webLinksAreNotFiles() {
        #expect(FileLinkResolver.parse("https://github.com/x/y") == nil)
        #expect(FileLinkResolver.resolve("https://github.com/x/y", threadDirectory: nil, roots: roots) { _ in true } == nil)
    }

    @Test func anAbsolutePathInASandboxIsTheTasksVersion() {
        let result = resolve("/sb/task/gh-next/README.md:3", existing: ["/sb/task/gh-next/README.md"])
        #expect(result?.candidates == [.init(path: "/sb/task/gh-next/README.md", origin: .task(repo: "gh-next"), relativePath: "README.md")])
        #expect(result?.line == 3)
    }

    @Test func anAbsolutePathInABaseCheckoutIsTheBase() {
        let result = resolve("/work/hashup/src/index.ts", existing: ["/work/hashup/src/index.ts"])
        #expect(result?.candidates.first?.origin == .base(repo: "hashup"))
    }

    @Test func anAbsolutePathElsewhereIsExternal() {
        let result = resolve("/etc/hosts", existing: ["/etc/hosts"])
        #expect(result?.candidates == [.init(path: "/etc/hosts", origin: .external, relativePath: nil)])
    }

    @Test func aRelativePathWithoutItsRepositoryIsFoundInTheSandboxes() {
        let result = resolve("src/index.ts:10", from: "/sb/task", existing: ["/sb/task/hashup/src/index.ts"])
        #expect(result?.candidates.map(\.origin) == [.task(repo: "hashup")])
        #expect(result?.line == 10)
    }

    @Test func theThreadsOwnRepositoryComesFirst() {
        let existing: Set<String> = ["/sb/task/hashup/README.md", "/sb/task/gh-next/README.md"]
        let result = resolve("README.md", from: "/sb/task/gh-next/docs", existing: existing)
        #expect(result?.candidates.map(\.origin) == [.task(repo: "gh-next"), .task(repo: "hashup")])
    }

    @Test func theThreadDirectoryIsTriedFirst() {
        let existing: Set<String> = ["/sb/task/hashup/docs/a.md", "/sb/task/hashup/a.md"]
        let result = resolve("a.md", from: "/sb/task/hashup/docs", existing: existing)
        #expect(result?.candidates.first?.path == "/sb/task/hashup/docs/a.md")
        #expect(result?.candidates.count == 2)
    }

    @Test func withoutATaskARelativePathIsFoundInTheBases() {
        let bases = roots.map { FileLinkResolver.Root(name: $0.name, sandbox: nil, base: $0.base) }
        let result = resolve("src/index.ts", roots: bases, existing: ["/work/hashup/src/index.ts"])
        #expect(result?.candidates.map(\.origin) == [.base(repo: "hashup")])
    }

    @Test func nothingOnDiskMeansNoCandidate() {
        #expect(resolve("missing.ts", from: "/sb/task", existing: [])?.candidates.isEmpty == true)
    }

    @Test func dotSegmentsAreFolded() {
        let result = resolve("../hashup/src/index.ts", from: "/sb/task/gh-next", existing: ["/sb/task/hashup/src/index.ts"])
        #expect(result?.candidates.first?.relativePath == "src/index.ts")
    }
}
