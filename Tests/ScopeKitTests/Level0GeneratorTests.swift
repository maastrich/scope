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

    @Test func readmeFirstParagraphSkipsTablesAndInlineCode() throws {
        let readme = """
        # Front

        | Package | Description |
        | --- | --- |
        | `react-ui` | Design system |

        Shared `react` packages of the front. Built with `pnpm`.
        """
        #expect(Level0Generator.firstParagraph(ofReadme: readme) == "Shared react packages of the front. Built with pnpm.")
        #expect(Level0Generator.firstParagraph(ofReadme: "| a | b |\n|---|---|\n") == nil)
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

    /// The openings real READMEs had instead of a description (two real scopes, 2026-10-22).
    @Test func readmeSummarySkipsInstructionsAndBoilerplate() {
        let instructions = """
        # Front

        1. Create a personal access token with the read:packages scope.
        2. Add it to your env.

        The web app of the platform, as one pnpm monorepo. Each package deploys on its own.
        """
        #expect(Level0Generator.summary(ofReadme: instructions) == "The web app of the platform, as one pnpm monorepo.")
        #expect(Level0Generator.summary(ofReadme: "# faker-json\n\nTo install dependencies:\n\n```bash\nbun install\n```\n") == nil)
        #expect(Level0Generator.summary(ofReadme: "*Automatically synced with your v0.app deployments*\n\nA shelf of board games.\n")
                == "A shelf of board games.")
        #expect(Level0Generator.summary(ofReadme: "- item one\n- item two\n") == nil)
        let alert = "# front\n\n> [!WARNING]\n> Never commit the .env file.\n\nThe web app.\n"
        #expect(Level0Generator.summary(ofReadme: alert) == "The web app.")
        #expect(Level0Generator.summary(ofReadme: "# x\n\nThis project was created using `bun init` in bun v1.1.\n\nFakes JSON.\n") == "Fakes JSON.")
        #expect(Level0Generator.summary(ofReadme: "This repository will stay in sync with your deployed chats.\n") == nil)
        let url = "This is the build image used on the CI to build the front monorepo: https://github.com/acme/front\n"
        #expect(Level0Generator.summary(ofReadme: url) == "This is the build image used on the CI to build the front monorepo")
        #expect(Level0Generator.summary(ofReadme: "[![CI](https://ci/b.svg)](https://ci)\n\nResolves every import. Then hashes.\n")
                == "Resolves every import.")
    }

    @Test func manifestDescriptions() throws {
        let cases: [([String: String], String?)] = [
            (["package.json": #"{"name":"x","description":"A darts scoreboard."}"#], "A darts scoreboard."),
            (["package.json": #"{"name":"x","description":"  "}"#], nil),
            (["Cargo.toml": "[package]\nname = \"x\"\ndescription = \"Formats TypeScript errors.\"\n[dependencies]\ndescription = \"no\"\n"],
             "Formats TypeScript errors."),
            (["pyproject.toml": "[project]\nname = \"x\"\ndescription = 'Lambda helpers.'\n"], "Lambda helpers."),
            (["pyproject.toml": "[tool.poetry]\ndescription = \"Poetry one.\"\n"], "Poetry one."),
            (["composer.json": #"{"description":"The ad platform backend."}"#], "The ad platform backend."),
        ]
        for (files, expected) in cases {
            let repo = try tempRepo(files)
            defer { try? FileManager.default.removeItem(at: repo) }
            #expect(Level0Generator.analyze(repo: repo).manifestDescription == expected, "\(files.keys.sorted())")
        }
    }

    /// A pyproject.toml that only configures ruff used to yield `pip install -e .` (or a driver's `uv sync`), which
    /// failed every task's setup. The Makefile's install target or the requirements files set the repo up instead.
    @Test func pythonWithoutAnInstallableProject() throws {
        let makefile = try tempRepo([
            "pyproject.toml": "[tool.ruff]\nline-length = 88\n", "requirements.txt": "boto3\n",
            "Makefile": "venv:\n\tuv venv\nlocal-install: venv\n\tuv pip install\nlocal-install-minimal: venv\n\tuv pip\ntest:\n\tpytest\nbootstrap:\n\t./scripts/codebuild/bootstrap.sh\n",
        ])
        defer { try? FileManager.default.removeItem(at: makefile) }
        let a = Level0Generator.analyze(repo: makefile)
        #expect(a.stack == ["python", "make"])
        #expect(a.setup == "make local-install" && a.test == "make test")

        let requirements = try tempRepo(["pyproject.toml": "[tool.black]\n", "requirements_dev.txt": "pytest\n", "tests/test_x.py": ""])
        defer { try? FileManager.default.removeItem(at: requirements) }
        let b = Level0Generator.analyze(repo: requirements)
        #expect(b.setup == "python3 -m venv .venv && .venv/bin/pip install -r requirements_dev.txt")
        #expect(b.test == ".venv/bin/pytest")

        // `uninstall` and `reinstall` end in "install" too, and the setup runs unattended.
        #expect(Level0Generator.setupTarget(in: ["uninstall", "reinstall", "pip-install", "build"]) == "pip-install")
        #expect(Level0Generator.setupTarget(in: ["uninstall", "build"]) == nil)

        let plain = try tempRepo(["requirements.txt": "flask\n"])
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(Level0Generator.analyze(repo: plain).stack == ["python"])
    }
}
