import Foundation
import ScopeCore
import ScopeDrivers

/// The second tier: the driver's `headlessAssist` argv — Claude Code's light model with no tools — asked for one JSON
/// object. The argv is checked before anything runs: an argv that could run a tool is refused, since what it reads
/// is untrusted terminal text (`headlessLight` is never used here).
public struct HeadlessAssistModel: AssistModel {
    public static let defaultTimeout: Duration = .seconds(45)

    public var profile: DriverProfile
    public var runner: any HeadlessRunner
    /// `SCOPE_HOME`, for the `{home}` placeholder.
    public var home: URL
    /// Where the driver runs. Nothing is read there: a tool-free call has no reason to look around.
    public var cwd: URL
    public var timeout: Duration

    public init(profile: DriverProfile, runner: any HeadlessRunner, home: URL, cwd: URL, timeout: Duration = defaultTimeout) {
        self.profile = profile
        self.runner = runner
        self.home = home
        self.cwd = cwd
        self.timeout = timeout
    }

    public var tier: AssistTier { .haiku }

    public var isAvailable: Bool {
        get async { Self.isToolFree(profile.headlessAssist ?? []) }
    }

    /// `true` for an argv that declares no tools: `--tools ""` present, and no `--allowedTools`, no
    /// `--dangerously-skip-permissions`. Anything else may act on what it reads.
    public static func isToolFree(_ argv: [String]) -> Bool {
        guard !argv.isEmpty else { return false }
        var sawEmptyTools = false
        var index = 0
        while index < argv.count {
            let argument = argv[index]
            switch argument {
            case "--tools":
                guard index + 1 < argv.count, argv[index + 1].trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                sawEmptyTools = true
                index += 1
            case "--allowedTools", "--allowed-tools", "--dangerously-skip-permissions":
                return false
            default:
                if argument.hasPrefix("--tools=") { return argument == "--tools=" && { sawEmptyTools = true; return true }() }
                if argument.hasPrefix("--allowedTools=") || argument.hasPrefix("--allowed-tools=") { return false }
            }
            index += 1
        }
        return sawEmptyTools
    }

    public func classify<T: Decodable & Sendable>(instructions: String, input: String, schema: AssistSchema) async throws -> T {
        guard let argv = profile.headlessAssist, Self.isToolFree(argv) else { throw AssistError.argvAllowsTools }
        let prompt = Self.prompt(instructions: instructions, input: input, schema: schema)
        let values = PlaceholderValues(threadID: "assist", cwd: cwd.path, scope: cwd.path, home: home.path, prompt: prompt)
        let expanded = try values.expand(argv)
        let result = try await runner.run(argv: expanded, cwd: cwd, timeout: timeout)
        guard result.succeeded else {
            let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HeadlessError.driverReportedError(text.isEmpty ? "\(profile.name) exited \(result.exitCode)" : text)
        }
        return try Self.parse(result.stdoutText)
    }

    /// The whole prompt: the instructions, the schema, then the untrusted input last.
    public static func prompt(instructions: String, input: String, schema: AssistSchema) -> String {
        """
        \(instructions)

        Answer with exactly one JSON object and nothing else, with these fields:
        \(schema.promptText)

        \(input)
        """
    }

    /// The object out of a `claude -p --output-format json` answer.
    public static func parse<T: Decodable>(_ output: String) throws -> T {
        let json = try HeadlessOutput.extractJSONObject(from: output)
        guard let data = json.data(using: .utf8), !json.isEmpty else { throw AssistError.malformedAnswer(output) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AssistError.malformedAnswer(json)
        }
    }
}
