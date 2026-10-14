import Foundation
import ScopeCore
import ScopeDrivers

/// Why a level-1 run produced no card.
public enum Level1Error: Error, Sendable, Equatable, CustomStringConvertible {
    /// The driver profile has no `headless` argv.
    case noHeadlessArgv(driver: String)
    /// `argv[0]` is not on PATH.
    case commandNotFound(String)
    /// A `{placeholder}` of the argv could not be expanded.
    case badArgv(String)
    /// The driver exited non-zero or reported an error; `message` is its trimmed stderr / error text.
    case driverFailed(message: String)
    /// The driver outlived the timeout.
    case timedOut
    /// The output (after unwrapping the envelope and fences) is not JSON.
    case notJSON(String)
    /// A required field is missing or has the wrong type.
    case invalidSchema(String)

    public var description: String {
        switch self {
        case .noHeadlessArgv(let driver): "driver \"\(driver)\" has no headless argv"
        case .commandNotFound(let command): "\"\(command)\" not found on PATH"
        case .badArgv(let reason): "headless argv: \(reason)"
        case .driverFailed(let message): "driver failed: \(message)"
        case .timedOut: "driver timed out"
        case .notJSON(let text): "driver output is not JSON: \(text.prefix(200))"
        case .invalidSchema(let reason): "driver JSON rejected: \(reason)"
        }
    }
}

/// Level 1 generation (spec §4.6): the default driver in headless mode, asked for strict JSON.
public struct Level1Generator: Sendable {
    public var profile: DriverProfile
    public var runner: any HeadlessRunner
    public var timeout: Duration
    /// `SCOPE_HOME`, for the `{home}` placeholder.
    public var home: URL

    public init(profile: DriverProfile, runner: any HeadlessRunner, home: URL, timeout: Duration = .seconds(120)) {
        self.profile = profile
        self.runner = runner
        self.home = home
        self.timeout = timeout
    }

    /// Runs the driver in `repo` and returns `seed` refined with the driver's answer (`generatedBy = .level1`).
    ///
    /// - Parameters:
    ///   - seed: the level-0 card, given to the driver as a starting point.
    ///   - otherRepos: graph keys of the scope's other repos, the only values accepted in `related`.
    public func generate(repo: URL, scopeRoot: URL, seed: RepoCard, otherRepos: [String]) async throws -> RepoCard {
        guard let headless = profile.headless, !headless.isEmpty else {
            throw Level1Error.noHeadlessArgv(driver: profile.id)
        }
        let prompt = Self.prompt(seed: seed, otherRepos: otherRepos)
        let values = PlaceholderValues(
            threadID: "graph", cwd: repo.path, scope: scopeRoot.path, home: home.path, prompt: prompt
        )
        let argv: [String]
        do {
            argv = try values.expand(headless)
        } catch {
            throw Level1Error.badArgv(String(describing: error))
        }
        let result: ProcessResult
        do {
            result = try await runner.run(argv: argv, cwd: repo, timeout: timeout)
        } catch let error as Level1Error {
            throw error
        } catch HeadlessError.commandNotFound(let command) {
            throw Level1Error.commandNotFound(command)
        } catch SubprocessError.timedOut {
            throw Level1Error.timedOut
        } catch {
            throw Level1Error.driverFailed(message: String(describing: error))
        }
        guard result.succeeded else {
            let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Level1Error.driverFailed(message: text.isEmpty ? "exit \(result.exitCode)" : text)
        }
        return try Self.parse(output: result.stdoutText, seed: seed, otherRepos: otherRepos)
    }

    // MARK: - Prompt

    /// Bumped whenever the prompt asks for something else: a card an older prompt wrote is then redone by the
    /// next analysis with AI, instead of keeping an answer to a question no longer asked. 2: the purpose as one
    /// skill-like sentence.
    public static let promptVersion = 2

    /// The JSON schema the driver must follow, as shown in the prompt.
    public static let schema = """
    {
      "purpose": "string, one sentence: what this repository does and when to work in it",
      "stack": ["string: languages, frameworks, notable tools, lowercase"],
      "entrypoints": ["string: relative paths of the main entry points"],
      "related": [{"kind": "depends_on" | "consumed_by", "repo": "string: one of the other repositories"}],
      "setup": "string or null: command to run after a fresh checkout",
      "test": "string or null: command that runs the tests",
      "tags": ["string: short lowercase keywords"]
    }
    """

    /// The headless prompt: task, schema, the level-0 seed and the other repos.
    public static func prompt(seed: RepoCard, otherRepos: [String]) -> String {
        let encoder = JSONStore.makeEncoder()
        let seedJSON = (try? encoder.encode(Level1Payload(seed: seed))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let others = otherRepos.isEmpty ? "(none)" : otherRepos.sorted().joined(separator: ", ")
        return """
        You are describing the repository in the current directory for a coding agent that has never seen it \
        and must decide, from one line, whether its task belongs here. Look at what the repository is made of \
        before what it says about itself: its manifests, its directory layout, its entry points and the main \
        source files, then the README. Answer with a single JSON object and nothing else: no prose, no \
        markdown fences, no comments.

        Required JSON shape:
        \(schema)

        Rules:
        - "purpose" is required: exactly one plain sentence, at most 200 characters, written like the \
        description of a skill — what the repository does, then when to work in it ("Renders the marketing \
        site from MDX; work here for landing pages, pricing and the blog."). Start with a verb. Say what the \
        code does, not what the README announces: no tagline, no install instruction, no "This repository", \
        no project name, no marketing adjective.
        - "related" may only reference these other repositories of the same workspace: \(others). \
        Use an empty array when unsure.
        - "setup" and "test" are shell commands run from the repository root; use null when unknown.
        - Keep every array short (at most 10 items).

        Facts already known (refine or correct them). The "purpose" below is only the first paragraph of \
        the README: a starting point to check against the code, never the answer to copy.
        \(seedJSON)
        """
    }

    // MARK: - Parsing

    /// Unwraps `claude --output-format json` envelopes and ```json fences (`HeadlessOutput`), decodes
    /// the payload, validates it and merges it into `seed`.
    public static func parse(output: String, seed: RepoCard, otherRepos: [String]) throws -> RepoCard {
        let payload = try decodePayload(output)
        guard let purpose = payload.purpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty else {
            throw Level1Error.invalidSchema("\"purpose\" is required")
        }
        var card = seed
        // One line whatever came back: the purpose is a list item in every task's context file.
        card.purpose = purpose.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        card.stack = clean(payload.stack ?? seed.stack)
        card.entrypoints = clean(payload.entrypoints ?? seed.entrypoints)
        card.tags = clean(payload.tags ?? seed.tags)
        card.setup = nonEmpty(payload.setup) ?? seed.setup
        card.test = nonEmpty(payload.test) ?? seed.test
        let allowed = Set(otherRepos)
        card.related = (payload.related ?? []).compactMap { raw -> Relation? in
            guard let kind = Relation.Kind(rawValue: raw.kind), allowed.contains(raw.repo) else { return nil }
            return Relation(kind: kind, repo: raw.repo)
        }
        card.generatedBy = .level1
        card.promptVersion = promptVersion
        return card
    }

    static func decodePayload(_ output: String) throws -> Level1Payload {
        let text: String
        do {
            text = try HeadlessOutput.extractJSONObject(from: output)
        } catch HeadlessError.driverReportedError(let message) {
            throw Level1Error.driverFailed(message: message)
        }
        guard !text.isEmpty else { throw Level1Error.notJSON("") }
        do {
            return try JSONDecoder().decode(Level1Payload.self, from: Data(text.utf8))
        } catch let error as DecodingError {
            if case .typeMismatch(_, let context) = error {
                throw Level1Error.invalidSchema(context.debugDescription)
            }
            throw Level1Error.notJSON(text)
        } catch {
            throw Level1Error.notJSON(text)
        }
    }

    private static func clean(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(10).map { $0 }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The JSON object exchanged with the driver (a subset of `RepoCard`).
struct Level1Payload: Codable {
    struct RawRelation: Codable {
        var kind: String
        var repo: String
    }

    var purpose: String?
    var stack: [String]?
    var entrypoints: [String]?
    var related: [RawRelation]?
    var setup: String?
    var test: String?
    var tags: [String]?

    init(seed: RepoCard) {
        purpose = seed.purpose
        stack = seed.stack
        entrypoints = seed.entrypoints
        related = seed.related.map { RawRelation(kind: $0.kind.rawValue, repo: $0.repo) }
        setup = seed.setup
        test = seed.test
        tags = seed.tags
    }
}
