import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

@Suite struct BaseOperationsTests {
    /// A second clone of `api`'s bare origin, used to push commits the base does not have.
    private func makeSecondClone(_ scope: TestScope, of repo: URL) async throws -> URL {
        let bare = scope.root.appending(path: "remotes/api.git", directoryHint: .isDirectory)
        let other = scope.root.appending(path: "other", directoryHint: .isDirectory)
        let client = await scope.client(for: scope.root)
        try await client.run(["clone", "-q", bare.path, other.path])
        return other
    }

    @Test func fastForwardPullBehindCountAndDiverged() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api")
        let other = try await makeSecondClone(scope, of: api)
        try scope.write(other, "feature.txt", "1\n")
        try await scope.commit(in: other, "remote change")
        try await scope.client(for: other).run(["push", "-q", "origin", "main"])

        let client = await scope.client(for: api)
        #expect(try await client.behindCount() == 1)
        #expect(try await client.behindCount(fetch: false) == 1)
        try await client.pullFastForward()
        #expect(scope.exists(api.appending(path: "feature.txt")))
        #expect(try await client.behindCount() == 0)
        try await client.pullFastForward()   // up to date: no-op

        // Diverge: a local commit and another remote commit.
        try scope.write(api, "local.txt", "l\n")
        try await scope.commit(in: api, "local change")
        try scope.write(other, "feature.txt", "2\n")
        try await scope.commit(in: other, "second remote change")
        try await scope.client(for: other).run(["push", "-q", "origin", "main"])
        await #expect(throws: BaseError.diverged(branch: "main", upstream: "origin/main")) {
            try await client.pullFastForward()
        }
        #expect(try await client.behindCount() == 1)

        try await client.run(["checkout", "-q", "--detach"])
        await #expect(throws: BaseError.noBranch) { try await client.pullFastForward() }
    }

    @Test func historyTreeSearchAndReadFile() async throws {
        let scope = try await TestScope.make()
        let api = try await scope.makeRepo("api", withOrigin: false)
        try scope.write(api, ".gitignore", "node_modules/\n*.log\n")
        try scope.write(api, "src/index.ts", "export const needle = 1;\nconst hay = 2;\n")
        try scope.write(api, "src/lib/util.ts", "// needle in a util\n")
        try await scope.commit(in: api, "second: add sources")
        try scope.write(api, "node_modules/x/index.js", "needle")   // ignored
        try scope.write(api, "debug.log", "needle")                 // ignored
        try scope.write(api, "untracked.txt", "needle untracked\n")  // untracked, not ignored
        let client = await scope.client(for: api)

        let history = try await client.recentHistory(limit: 10)
        #expect(history.count == 2 && history[0].subject == "second: add sources" && history[1].subject == "initial")
        #expect(history[0].author == "Scope Tests" && history[0].short.count >= 7 && history[0].sha.hasPrefix(history[0].short))
        #expect(history[0].date >= history[1].date)
        #expect(try await client.recentHistory(limit: 1).count == 1)

        let tree = try await client.fileTree()
        #expect(tree.filePaths == ["src/lib/util.ts", "src/index.ts", ".gitignore", "README.md", "untracked.txt"])   // directories first, depth first
        #expect(tree.children.first?.name == "src" && tree.children.first?.isDirectory == true)
        #expect(tree.children.first?.children.first?.path == "src/lib")

        let hits = try await client.search(pattern: "needle", tool: .gitGrep)
        #expect(hits == [
            SearchMatch(path: "src/index.ts", line: 1, text: "export const needle = 1;"),
            SearchMatch(path: "src/lib/util.ts", line: 1, text: "// needle in a util"),
            SearchMatch(path: "untracked.txt", line: 1, text: "needle untracked"),
        ])
        #expect(try await client.search(pattern: "needle", in: "src/lib", tool: .gitGrep).count == 1)
        #expect(try await client.search(pattern: "absent-token", tool: .gitGrep).isEmpty)
        if case .ripgrep = SearchTool.locate() {
            let rg = try await client.search(pattern: "needle")
            #expect(Set(rg.map(\.path)) == Set(hits.map(\.path)))
        }

        #expect(try client.readFile(at: "src/index.ts").hasPrefix("export const needle"))
        #expect(throws: BaseError.notAFile(path: api.appending(path: "src").path)) { try client.readFile(at: "src") }
        #expect(throws: BaseError.notAFile(path: api.appending(path: "nope").path)) { try client.readFile(at: "nope") }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: api.appending(path: "img.png"))
        #expect(throws: BaseError.binaryFile(path: api.appending(path: "img.png").path)) { try client.readFile(at: "img.png") }
        try Data(count: BaseFiles.maxReadBytes + 1).write(to: api.appending(path: "big.bin"))
        #expect(throws: BaseError.fileTooLarge(path: api.appending(path: "big.bin").path, bytes: BaseFiles.maxReadBytes + 1)) {
            try client.readFile(at: "big.bin")
        }
    }

    @Test func parsersAndTreeBuilder() {
        let rg = """
        {"type":"begin","data":{"path":{"text":"./a.txt"}}}
        {"type":"match","data":{"path":{"text":"./a.txt"},"lines":{"text":"hello world\\n"},"line_number":3,"absolute_offset":10,"submatches":[]}}
        {"type":"end","data":{"path":{"text":"./a.txt"}}}
        garbage
        """
        #expect(GitClient.parseRipgrepJSON(rg) == [SearchMatch(path: "a.txt", line: 3, text: "hello world")])
        #expect(GitClient.parseGrepLines("a/b.rs:12:let x: i32 = 1;\nbad line\n") == [SearchMatch(path: "a/b.rs", line: 12, text: "let x: i32 = 1;")])
        let tree = FileNode.tree(paths: ["z.txt", "a/b/c.txt", "a/d.txt", "a/b/a.txt"])
        #expect(tree.children.map(\.name) == ["a", "z.txt"])
        #expect(tree.children[0].children.map(\.path) == ["a/b", "a/d.txt"])
        #expect(tree.children[0].children[0].children.map(\.name) == ["a.txt", "c.txt"])
    }
}
