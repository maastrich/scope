import Foundation
import ScopeCore
import ScopeDrivers

/// Runs a driver's headless argv. Injected so tests never start a real driver.
public protocol HeadlessRunner: Sendable {
    /// `argv[0]` is the command as written in the profile (`claude`), not yet resolved to a path.
    func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult
}

/// The real runner: resolves `argv[0]` on the login-shell PATH and runs it with `Subprocess`.
public struct SubprocessHeadlessRunner: HeadlessRunner {
    /// `PATH` used to resolve the command (the login-shell one, see `ShellEnvironmentResolver`).
    public var path: String
    /// Login shell for `$SHELL` commands.
    public var shell: String
    /// Extra environment merged over the process one.
    public var environment: [String: String]

    public init(path: String, shell: String = ShellEnvironment.loginShell(), environment: [String: String] = [:]) {
        self.path = path
        self.shell = shell
        self.environment = environment
    }

    public func run(argv: [String], cwd: URL, timeout: Duration) async throws -> ProcessResult {
        guard let command = argv.first, let executable = ExecutableResolver.resolve(command, path: path, shell: shell) else {
            throw Level1Error.commandNotFound(argv.first ?? "")
        }
        var env = environment
        env["PATH"] = path
        return try await Subprocess.run(
            executable: executable, arguments: Array(argv.dropFirst()), currentDirectory: cwd,
            environment: env, timeout: timeout
        )
    }
}

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

    /// The JSON schema the driver must follow, as shown in the prompt.
    public static let schema = """
    {
      "purpose": "string, 1 to 3 sentences: what this repository is for",
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
        You are describing the repository in the current directory for a developer who has never seen it. \
        Read its README, manifests and main source files, then answer with a single JSON object and nothing \
        else: no prose, no markdown fences, no comments.

        Required JSON shape:
        \(schema)

        Rules:
        - "purpose" is required: 1 to 3 plain sentences.
        - "related" may only reference these other repositories of the same workspace: \(others). \
        Use an empty array when unsure.
        - "setup" and "test" are shell commands run from the repository root; use null when unknown.
        - Keep every array short (at most 10 items).

        Facts already known (refine or correct them):
        \(seedJSON)
        """
    }

    // MARK: - Parsing

    /// Unwraps `claude --output-format json` envelopes (`{"result": "…"}`) and ```json fences, decodes
    /// the payload, validates it and merges it into `seed`.
    public static func parse(output: String, seed: RepoCard, otherRepos: [String]) throws -> RepoCard {
        let payload = try decodePayload(output)
        guard let purpose = payload.purpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty else {
            throw Level1Error.invalidSchema("\"purpose\" is required")
        }
        var card = seed
        card.purpose = purpose
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
        return card
    }

    static func decodePayload(_ output: String) throws -> Level1Payload {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Level1Error.notJSON("") }
        // Envelope from `claude -p --output-format json`.
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["result"] != nil || object["is_error"] != nil {
            if let isError = object["is_error"] as? Bool, isError {
                throw Level1Error.driverFailed(message: (object["result"] as? String) ?? "driver reported an error")
            }
            if let inner = object["result"] as? String {
                text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let inner = object["result"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: inner) {
                text = String(decoding: data, as: UTF8.self)
            }
        }
        text = stripFences(text)
        // Tolerate prose around the object: take the outermost `{ … }`.
        if !text.hasPrefix("{"), let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            text = String(text[open...close])
        }
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

    /// Removes a leading ```json / ``` line and a trailing ``` line.
    static func stripFences(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
