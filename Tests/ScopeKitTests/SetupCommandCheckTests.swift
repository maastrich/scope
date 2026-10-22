import Foundation
import Testing
@testable import ScopeTasks

@Suite struct SetupCommandCheckTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "scope-setup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let file = dir.appending(path: name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// The failure seen on five tasks: a pyproject.toml that only configures ruff, and a driver that answered `uv sync`.
    @Test func uvNeedsAProjectTable() throws {
        let toolsOnly = try folder(["pyproject.toml": "[tool.ruff]\nline-length = 88\n", "requirements.txt": "boto3\n"])
        #expect(SetupCommandCheck.problem("uv sync", in: toolsOnly) == "pyproject.toml has no [project] table")
        #expect(SetupCommandCheck.problem("uv run pytest", in: toolsOnly) != nil)
        #expect(SetupCommandCheck.problem("pip install -e .", in: toolsOnly) == "pyproject.toml declares no installable project")
        #expect(SetupCommandCheck.problem("pip install -r requirements.txt", in: toolsOnly) == nil)
        #expect(SetupCommandCheck.problem("pip install -r requirements_dev.txt", in: toolsOnly) == "there is no requirements_dev.txt")
        #expect(SetupCommandCheck.problem("poetry install", in: toolsOnly) == "pyproject.toml declares no Poetry project")
        // `uv pip …` does not read the project.
        #expect(SetupCommandCheck.problem("uv pip install -r requirements.txt", in: toolsOnly) == nil)

        let project = try folder(["pyproject.toml": "[project]\nname = \"x\"\n"])
        #expect(SetupCommandCheck.problem("uv sync", in: project) == nil)
        #expect(SetupCommandCheck.problem("pip install -e .", in: project) == nil)
    }

    @Test func makeTargetsMustExist() throws {
        let repo = try folder(["Makefile": "VENV := .venv\nvenv:\n\tuv venv\nlocal-install: venv\n\tuv pip install\nlint test: venv\n\truff\n"])
        #expect(SetupCommandCheck.problem("make local-install", in: repo) == nil)
        #expect(SetupCommandCheck.problem("make test", in: repo) == nil)
        #expect(SetupCommandCheck.problem("make install", in: repo) == "the Makefile has no install target")
        #expect(SetupCommandCheck.problem("make", in: repo) == nil)
        #expect(SetupCommandCheck.problem("make install", in: try folder([:])) == "there is no Makefile")
        // An include can define what this cannot see: no verdict.
        let included = try folder(["Makefile": "include common.mk\nbuild:\n\tcc\n"])
        #expect(SetupCommandCheck.problem("make install", in: included) == nil)
    }

    @Test func manifestsAndFoldersAreLookedForWhereTheCommandRuns() throws {
        let repo = try folder(["app/package.json": "{}", "Cargo.toml": ""])
        #expect(SetupCommandCheck.problem("cd app && npm install", in: repo) == nil)
        #expect(SetupCommandCheck.problem("npm install", in: repo) == "there is no package.json")
        #expect(SetupCommandCheck.problem("cd web && pnpm install", in: repo) == "there is no folder web")
        #expect(SetupCommandCheck.problem("cargo build && cd app && pnpm i", in: repo) == nil)
        #expect(SetupCommandCheck.problem("go mod download", in: repo) == "there is no go.mod")
        #expect(SetupCommandCheck.problem("bundle install", in: repo) == "there is no Gemfile")
        #expect(SetupCommandCheck.problem("swift build", in: repo) == "there is no Package.swift")
        #expect(SetupCommandCheck.problem("cd app && composer install", in: repo) == "there is no composer.json")
        #expect(SetupCommandCheck.problem("yarn", in: repo) == "there is no package.json")
    }

    /// A segment the check does not model may create what the next one needs: no verdict past it.
    @Test func noVerdictPastAToolItDoesNotKnow() throws {
        let empty = try folder([:])
        #expect(SetupCommandCheck.problem("./configure && make install", in: empty) == nil)
        #expect(SetupCommandCheck.problem("git submodule update --init && cd vendor/x && npm i", in: empty) == nil)
        // Before the unknown tool, the check still answers.
        #expect(SetupCommandCheck.problem("npm i && ./configure", in: empty) == "there is no package.json")
    }

    @Test func manifestsAreFoundInParentFoldersUpToTheRepo() throws {
        let repo = try folder(["go.mod": "module x\n", "tools/gen/main.go": "", "package.json": "{}", "web/src/x.ts": ""])
        #expect(SetupCommandCheck.problem("cd tools && go test ./...", in: repo) == nil)
        #expect(SetupCommandCheck.problem("cd web && npm test", in: repo) == nil)
        #expect(SetupCommandCheck.problem("cd tools && cargo build", in: repo) == "there is no Cargo.toml")
    }

    @Test func unknownToolsAndUnreadablePathsPass() throws {
        let empty = try folder([:])
        #expect(SetupCommandCheck.problem("docker compose build", in: empty) == nil)
        #expect(SetupCommandCheck.problem("./scripts/bootstrap.sh", in: empty) == nil)
        #expect(SetupCommandCheck.problem("cd $HOME && ls", in: empty) == nil)
        #expect(SetupCommandCheck.problem("npm --version", in: empty) == nil)
    }

    @Test func refusalsCollapseByReason() {
        let refusals = (1...5).map { SandboxFileCopy.Refusal(path: ".claude/skills/s\($0)", reason: "the sandbox has a symlink on that path") }
            + [SandboxFileCopy.Refusal(path: "../x", reason: "“..” would leave the repository")]
        let log = SetupLog.refusals(refusals, repo: "front")
        #expect(log == """
        [front] did not copy 5 paths (.claude/skills/s1, .claude/skills/s2 and 3 more): the sandbox has a symlink on that path
        [front] did not copy ../x: “..” would leave the repository

        """)
    }
}
