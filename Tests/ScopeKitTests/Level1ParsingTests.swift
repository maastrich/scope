import Foundation
import Testing
import ScopeCore
import ScopeDrivers
@testable import ScopeGraph

@Suite struct Level1ParsingTests {
    private let seed = RepoCard(name: "api", purpose: "Seed.", stack: ["node"], setup: "npm install", generatedBy: .level0)
    private let answer = #"{"purpose":"Serves the mobile app.","stack":["node","fastify"],"entrypoints":["src/index.ts"],"related":[{"kind":"consumed_by","repo":"web"},{"kind":"bogus","repo":"web"},{"kind":"depends_on","repo":"unknown"}],"setup":null,"test":"npm test","tags":["api"]}"#

    @Test func claudeEnvelopeIsUnwrapped() throws {
        let envelope = try JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": "success", "is_error": false, "result": answer, "session_id": "abc",
        ])
        let card = try Level1Generator.parse(output: String(decoding: envelope, as: UTF8.self), seed: seed, otherRepos: ["web"])
        #expect(card.purpose == "Serves the mobile app." && card.stack == ["node", "fastify"])
        #expect(card.related == [Relation(kind: .consumedBy, repo: "web")])   // bad kind / unknown repo dropped
        #expect(card.setup == "npm install" && card.test == "npm test")       // null keeps the seed value
        #expect(card.generatedBy == .level1 && card.name == "api")
    }

    @Test func fencedAndProseWrappedJSON() throws {
        let fenced = "Here you go:\n```json\n\(answer)\n```\n"
        #expect(try Level1Generator.parse(output: fenced, seed: seed, otherRepos: []).purpose == "Serves the mobile app.")
        let bare = "```\n\(answer)\n```"
        #expect(try Level1Generator.parse(output: bare, seed: seed, otherRepos: []).related == [])
    }

    @Test func invalidOutputsAreTypedErrors() {
        #expect(throws: Level1Error.notJSON("not json at all")) {
            try Level1Generator.parse(output: "not json at all", seed: seed, otherRepos: [])
        }
        #expect(throws: Level1Error.invalidSchema("\"purpose\" is required")) {
            try Level1Generator.parse(output: #"{"stack":["x"]}"#, seed: seed, otherRepos: [])
        }
        #expect(throws: Level1Error.self) {
            try Level1Generator.parse(output: #"{"purpose":"ok","stack":"not-an-array"}"#, seed: seed, otherRepos: [])
        }
        #expect(throws: Level1Error.driverFailed(message: "rate limited")) {
            try Level1Generator.parse(output: #"{"type":"result","is_error":true,"result":"rate limited"}"#, seed: seed, otherRepos: [])
        }
        #expect(throws: Level1Error.notJSON("")) {
            try Level1Generator.parse(output: "  \n", seed: seed, otherRepos: [])
        }
    }

    @Test func promptCarriesSchemaSeedAndOtherRepos() {
        let prompt = Level1Generator.prompt(seed: seed, otherRepos: ["web", "docs"])
        #expect(prompt.contains("\"purpose\"") && prompt.contains("depends_on"))
        #expect(prompt.contains("docs, web") && prompt.contains("\"Seed.\""))
        // The purpose is asked as one skill-like sentence drawn from the code, with the README excerpt flagged.
        #expect(prompt.contains("exactly one plain sentence") && prompt.contains("never the answer to copy"))
    }

    @Test func aPurposeSpreadOverLinesIsKeptOnOne() throws {
        let card = try Level1Generator.parse(output: #"{"purpose":"Resolves imports.\n  Work here for hashing."}"#, seed: seed, otherRepos: [])
        #expect(card.purpose == "Resolves imports. Work here for hashing.")
    }

    @Test func generateExpandsHeadlessArgvAndRunsInRepo() async throws {
        struct Recorder: HeadlessRunner {
            let out: String
            let box: Recorded
            func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
                await box.record(argv: argv, cwd: cwd)
                return ProcessResult(exitCode: 0, terminationReason: .exit, stdout: Data(out.utf8), stderr: Data())
            }
        }
        actor Recorded {
            var argv: [String] = []
            var cwd: URL?
            func record(argv: [String], cwd: URL) { self.argv = argv; self.cwd = cwd }
        }
        let recorded = Recorded()
        let profile = try DriverRegistry.bundledProfiles().first { $0.id == "claude-code" }!
        let generator = Level1Generator(profile: profile, runner: Recorder(out: answer, box: recorded), home: URL(fileURLWithPath: "/tmp/h"))
        let repo = URL(fileURLWithPath: "/tmp/scope/api", isDirectory: true)
        let card = try await generator.generate(repo: repo, scopeRoot: repo.deletingLastPathComponent(), seed: seed, otherRepos: ["web"])
        #expect(card.purpose == "Serves the mobile app.")
        let argv = await recorded.argv
        #expect(argv.prefix(2) == ["claude", "-p"] && argv.suffix(2) == ["--output-format", "json"])
        #expect(argv[2].contains("Required JSON shape"))
        #expect(await recorded.cwd == repo)

        let noHeadless = DriverProfile(id: "shell", name: "Shell", command: "$SHELL")
        let bare = Level1Generator(profile: noHeadless, runner: Recorder(out: "", box: recorded), home: repo)
        await #expect(throws: Level1Error.noHeadlessArgv(driver: "shell")) {
            try await bare.generate(repo: repo, scopeRoot: repo, seed: seed, otherRepos: [])
        }
    }

    @Test func domainIsKeptOnlyWhenItIsOne() throws {
        let card = try Level1Generator.parse(output: #"{"purpose":"Serves the API.","domain":"Backend"}"#, seed: seed, otherRepos: [])
        #expect(card.domain == "backend" && card.promptVersion == Level1Generator.promptVersion)
        let unknown = try Level1Generator.parse(output: #"{"purpose":"Serves the API.","domain":"marketing"}"#, seed: seed, otherRepos: [])
        #expect(unknown.domain == nil)
        #expect(Level1Generator.prompt(seed: seed, otherRepos: []).contains("\"domain\": \"one of: frontend, backend"))
    }

    /// The driver answered `uv sync` for a repository whose pyproject.toml only configures ruff: the quick analysis's
    /// command, checked against the files, is kept instead.
    @Test func aCommandTheFilesRuleOutFallsBackToTheSeed() async throws {
        struct Canned: HeadlessRunner {
            let out: String
            func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
                ProcessResult(exitCode: 0, terminationReason: .exit, stdout: Data(out.utf8), stderr: Data())
            }
        }
        let repo = FileManager.default.temporaryDirectory.appending(path: "scope-l1-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "[tool.ruff]\n".write(to: repo.appending(path: "pyproject.toml"), atomically: true, encoding: .utf8)
        try "local-install:\n\tuv pip install\ntest:\n\tpytest\n".write(to: repo.appending(path: "Makefile"), atomically: true, encoding: .utf8)
        let python = RepoCard(name: "billing", stack: ["python"], setup: "make local-install", test: "make test", generatedBy: .level0)
        let profile = try DriverRegistry.bundledProfiles().first { $0.id == "claude-code" }!
        let generator = Level1Generator(profile: profile, runner: Canned(out: #"{"purpose":"Serves billing.","setup":"uv sync","test":"make test"}"#),
                                        home: repo)
        let card = try await generator.generate(repo: repo, scopeRoot: repo, seed: python, otherRepos: [])
        #expect(card.setup == "make local-install" && card.test == "make test")
    }
}
