import Foundation
import Testing
import ScopeCore
import ScopeGit
@testable import ScopeGraph

@Suite struct Level0GeneratorTests {
    private func tempRepo(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "scope-l0-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (name, content) in files {
            let file = dir.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readmeFirstParagraphSkipsBadgesHeadingsAndHTML() throws {
        let readme = """
        <p align="center"><img src="logo.png" width="100"></p>

        # Acme API

        [![CI](https://ci/badge.svg)](https://ci) ![npm](https://img.shields.io/npm/v/acme)
        <!-- a comment -->

        > **Acme API** is the backend of [Acme](https://acme.dev). It serves the mobile app.
        It also exposes webhooks. Fourth sentence must be dropped.

        ## Install

        Run `npm i`.
        """
        let paragraph = Level0Generator.firstParagraph(ofReadme: readme)
        #expect(paragraph == "Acme API is the backend of Acme. It serves the mobile app. It also exposes webhooks.")
        #expect(Level0Generator.firstParagraph(ofReadme: "# Title only\n\n## Sub\n") == nil)
        #expect(Level0Generator.firstParagraph(ofReadme: "Title\n=====\n\nOne line.\n") == "One line.")
        #expect(Level0Generator.firstParagraph(ofReadme: "```sh\nnpm i\n```\nAfter the fence.") == "After the fence.")
    }

    @Test func packageJSONInference() throws {
        let repo = try tempRepo([
            "README.md": "# web\n\nThe web front.\n",
            "package.json": """
            {"name":"web","main":"dist/index.js","bin":{"web":"bin/web.js"},
             "scripts":{"build":"tsc","test":"vitest","dev":"vite"},
             "devDependencies":{"typescript":"^5","vite":"^5"},"workspaces":["packages/*"]}
            """,
            "pnpm-lock.yaml": "lockfileVersion: 9\n",
        ])
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = Level0Generator.analyze(repo: repo)
        #expect(a.purpose == "The web front.")
        #expect(a.stack == ["node", "typescript", "vite"])
        #expect(a.setup == "pnpm install" && a.test == "pnpm test")
        #expect(a.entrypoints == ["dist/index.js", "bin/web.js"])
        #expect(a.tags.contains("monorepo") && a.tags.contains("node"))
        #expect(a.manifests == ["package.json"])

        let declared = try tempRepo(["package.json": #"{"packageManager":"bun@1.1.0","scripts":{}}"#])
        defer { try? FileManager.default.removeItem(at: declared) }
        let b = Level0Generator.analyze(repo: declared)
        #expect(b.setup == "bun install" && b.test == nil && b.purpose == nil)
    }

    @Test func otherManifestKinds() throws {
        let cases: [(files: [String: String], stack: String, setup: String, test: String)] = [
            (["Cargo.toml": "[package]\nname = \"x\"\n", "src/main.rs": "fn main(){}"], "rust", "cargo build", "cargo test"),
            (["pyproject.toml": "[tool.poetry]\nname = \"x\"\n"], "python", "poetry install", "poetry run pytest"),
            (["pyproject.toml": "[project]\nname = \"x\"\n", "uv.lock": ""], "python", "uv sync", "uv run pytest"),
            (["pyproject.toml": "[project]\nname = \"x\"\n"], "python", "pip install -e .", "pytest"),
            (["go.mod": "module x\n", "main.go": "package main", "cmd/tool/main.go": "package main"], "go", "go mod download", "go test ./..."),
            (["Package.swift": "// swift-tools-version: 6.0\n"], "swift", "swift build", "swift test"),
            (["Gemfile": "source 'https://rubygems.org'\n", "spec/x_spec.rb": ""], "ruby", "bundle install", "bundle exec rspec"),
            (["Makefile": "CC := cc\n.PHONY: all\nall: build\nsetup:\n\t./configure\ntest:\n\tgo test\n"], "make", "make setup", "make test"),
        ]
        for c in cases {
            let repo = try tempRepo(c.files)
            defer { try? FileManager.default.removeItem(at: repo) }
            let a = Level0Generator.analyze(repo: repo)
            #expect(a.stack == [c.stack], "\(c.files.keys.sorted())")
            #expect(a.setup == c.setup && a.test == c.test, "\(c.files.keys.sorted())")
            if c.stack == "rust" { #expect(a.entrypoints == ["src/main.rs"]) }
            if c.stack == "go" { #expect(a.entrypoints == ["main.go", "cmd/tool"]) }
        }
        // Makefile after package.json: package.json wins for setup/test, make adds to the stack.
        let both = try tempRepo(["package.json": #"{"scripts":{"test":"jest"}}"#, "Makefile": "test:\n\tjest\n"])
        defer { try? FileManager.default.removeItem(at: both) }
        let a = Level0Generator.analyze(repo: both)
        #expect(a.setup == "npm install" && a.test == "npm test" && a.stack == ["node", "make"])
    }

    @Test func cacheKeyIsStableAndSensitive() async throws {
        let scope = try await TestScope.make()
        let repo = try await scope.makeRepo("api", withOrigin: false)
        try scope.write(repo, "package.json", #"{"name":"api"}"#)
        try await scope.commit(in: repo, "manifest")
        let client = await scope.client(for: repo)

        let first = await Level0Generator.cacheKey(repo: repo, using: client)
        let again = await Level0Generator.cacheKey(repo: repo, using: client)
        #expect(first == again)
        let head = try await client.output(["rev-parse", "HEAD"])
        #expect(first.hasPrefix(head + ":"))

        try scope.write(repo, "README.md", "# api\n\nChanged.\n")   // uncommitted README edit changes the key
        let readmeChanged = await Level0Generator.cacheKey(repo: repo, using: client)
        #expect(readmeChanged != first)
        try await scope.commit(in: repo, "readme")
        let committed = await Level0Generator.cacheKey(repo: repo, using: client)
        #expect(committed != readmeChanged && committed != first)

        let (card, key) = await Level0Generator.generate(repo: repo, name: "api", using: client)
        #expect(key == committed)
        #expect(card.name == "api" && card.purpose == "Changed." && card.stack == ["node"])
        #expect(card.defaultBranch == "main" && card.generatedBy == .level0)
        #expect(card.lastActivity != nil && abs(card.lastActivity!.timeIntervalSinceNow) < 600)
    }
}
