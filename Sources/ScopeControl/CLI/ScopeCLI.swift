import Foundation

/// Argument parsing for the `scope` binary — pure, so the CLI itself is twenty lines of plumbing and every
/// spelling decision is covered by a test.
public enum ScopeCLI {
    /// Options that apply to any command.
    public struct Options: Sendable, Equatable {
        /// `--sock`
        public var socket: String?
        /// `--home`
        public var home: String?
        /// `--json`: print the result exactly as it came off the socket.
        public var json: Bool

        public init(socket: String? = nil, home: String? = nil, json: Bool = false) {
            self.socket = socket
            self.home = home
            self.json = json
        }
    }

    /// What the command line asked for.
    public enum Invocation: Sendable, Equatable {
        case help(String)
        case version
        case call(ControlCall, Options)
        /// `scope mcp` — the same commands, spoken as MCP on stdio.
        case mcp(Options)
    }

    /// A command line that says nothing usable.
    public struct UsageError: Error, Sendable, Equatable, CustomStringConvertible {
        public var message: String
        public var usage: String
        public var description: String { "\(message)\n\n\(usage)" }
    }

    public static let usage = """
    usage: scope <command> [options]

      scope list [scopes|threads|tasks]   what Scope is holding right now
      scope thread new [options]          open a thread and print its id
      scope thread stop <id>              stop the thread's process (the row stays)
      scope thread close <id>             hang it up and remove it
      scope thread send <id> <text>       type <text> into it and press ↩ (--no-enter to leave it on the line)
      scope task new <prompt> [options]   sandbox a task (branch + worktrees) and open its first thread
      scope task close <id|slug>          close a task: threads hung up, worktrees removed
                                          (--delete-branch, --force to lose uncommitted work)
      scope mcp                           speak MCP on stdio, same commands
      scope ping                          check that Scope is listening

    thread new:
      --scope <slug|name|id|path>   which scope (default: the caller's, else the one holding the cwd)
      --driver <id>                 driver profile (default: the scope's usual one)
      --task <id|slug>              open it inside that task's sandbox
      --repo <relative/path>        open it in that repository
      --title <text>                row label
      -p, --prompt <text>           first thing the driver is asked

    task new:
      --scope <slug|name|id|path>   which scope
      --repo <relative/path>        repository to sandbox; repeat for several (default: proposed)
      --branch <name>               branch to create (default: proposed from the prompt)
      --title <text>                task name (default: proposed)
      --slug <name>                 sandbox folder name (default: from the title)
      --driver <id>                 driver for the first thread
      --dry-run                     print the proposal, create nothing
      --no-thread                   create the task without opening a thread
      --no-setup                    skip the repositories' setup commands (.env files are still copied)

    list:
      --scope <slug|name|id|path>   only that scope

    options:
      --json                        machine-readable output
      --sock <path>                 socket to talk to (default: $SCOPE_SOCK, else <SCOPE_HOME>/scope.sock)
      --home <path>                 Scope home to derive the socket from
      -h, --help                    this text
      --version                     the CLI's own version

    Anything that can write to the socket file can drive Scope; it is 0600 and lives in SCOPE_HOME.
    """

    /// Parses `arguments` (without the binary name).
    public static func parse(_ arguments: [String]) throws -> Invocation {
        var rest = arguments[...]
        guard let first = rest.first else { return .help(usage) }
        if first == "-h" || first == "--help" { return .help(usage) }
        if first == "--version" { return .version }
        rest = rest.dropFirst()

        switch first {
        case "ping":
            return .call(.ping, try options(&rest, command: "ping"))
        case "mcp":
            return .mcp(try options(&rest, command: "mcp"))
        case "list":
            var kind = ListParams.Kind.all
            if let word = rest.first, !word.hasPrefix("-") {
                guard let parsed = ListParams.Kind(rawValue: word) else {
                    throw UsageError(message: "list takes one of: " + ListParams.Kind.allCases.map(\.rawValue).joined(separator: ", "),
                                     usage: usage)
                }
                kind = parsed
                rest = rest.dropFirst()
            }
            var parameters = ListParams(kind: kind)
            let shared = try options(&rest, command: "list", specific: { flag, value in
                switch flag {
                case "--scope": parameters.scope = try value()
                default: return false
                }
                return true
            })
            return .call(.list(parameters), shared)
        case "thread":
            let sub = rest.first
            rest = rest.dropFirst()
            switch sub {
            case "stop", "close":
                var words: [String] = []
                let shared = try options(&rest, command: "thread \(sub!)", positional: { words.append($0) })
                guard words.count == 1 else { throw UsageError(message: "thread \(sub!) takes one thread id", usage: usage) }
                let target = ThreadTargetParams(thread: words[0])
                return .call(sub == "stop" ? .threadStop(target) : .threadClose(target), shared)
            case "send":
                var words: [String] = []
                var submit = true
                let shared = try options(&rest, command: "thread send", positional: { words.append($0) }, specific: { flag, _ in
                    guard flag == "--no-enter" else { return false }
                    submit = false
                    return true
                })
                guard words.count >= 2 else { throw UsageError(message: "thread send takes a thread id and the text to type", usage: usage) }
                return .call(.threadSend(ThreadSendParams(thread: words[0], text: words.dropFirst().joined(separator: " "),
                                                          submit: submit)), shared)
            case "new":
                break
            default:
                throw UsageError(message: "thread commands: new, stop, close, send", usage: usage)
            }
            var parameters = ThreadNewParams()
            let shared = try options(&rest, command: "thread new", specific: { flag, value in
                switch flag {
                case "--scope": parameters.scope = try value()
                case "--driver": parameters.driver = try value()
                case "--task": parameters.task = try value()
                case "--repo": parameters.repo = try value()
                case "--title": parameters.title = try value()
                case "-p", "--prompt": parameters.prompt = try value()
                default: return false
                }
                return true
            })
            return .call(.threadNew(parameters), shared)
        case "task":
            let sub = rest.first
            rest = rest.dropFirst()
            if sub == "close" {
                var words: [String] = []
                var parameters = TaskCloseParams(task: "")
                let shared = try options(&rest, command: "task close", positional: { words.append($0) }, specific: { flag, _ in
                    switch flag {
                    case "--delete-branch": parameters.deleteBranch = true
                    case "--force": parameters.force = true
                    default: return false
                    }
                    return true
                })
                guard words.count == 1 else { throw UsageError(message: "task close takes one task id or slug", usage: usage) }
                parameters.task = words[0]
                return .call(.taskClose(parameters), shared)
            }
            guard sub == "new" else {
                throw UsageError(message: "task commands: new, close", usage: usage)
            }
            var prompt: [String] = []
            var parameters = TaskNewParams(prompt: "")
            let shared = try options(&rest, command: "task new", positional: { prompt.append($0) }, specific: { flag, value in
                switch flag {
                case "--scope": parameters.scope = try value()
                case "--repo": parameters.repos.append(try value())
                case "--branch": parameters.branch = try value()
                case "--title": parameters.title = try value()
                case "--slug": parameters.slug = try value()
                case "--driver": parameters.driver = try value()
                case "-p", "--prompt": prompt.append(try value())
                case "--dry-run": parameters.dryRun = true
                case "--no-thread": parameters.openThread = false
                case "--no-setup": parameters.runSetup = false
                default: return false
                }
                return true
            })
            parameters.prompt = prompt.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !parameters.prompt.isEmpty else {
                throw UsageError(message: "task new needs a prompt: what is the task about?", usage: usage)
            }
            return .call(.taskNew(parameters), shared)
        default:
            throw UsageError(message: "unknown command “\(first)”", usage: usage)
        }
    }

    /// Consumes the shared options plus whatever `specific` claims. Flags that take a value accept both
    /// `--flag value` and `--flag=value`.
    private static func options(_ rest: inout ArraySlice<String>, command: String,
                                positional: ((String) -> Void)? = nil,
                                specific: ((String, () throws -> String) throws -> Bool)? = nil) throws -> Options {
        var options = Options()
        // A local copy: the value-taking closure below would otherwise capture an `inout` parameter.
        var remaining = rest
        defer { rest = remaining }
        while let argument = remaining.first {
            remaining = remaining.dropFirst()
            var flag = argument
            var inlineValue: String?
            if flag.hasPrefix("--"), let equals = flag.firstIndex(of: "=") {
                inlineValue = String(flag[flag.index(after: equals)...])
                flag = String(flag[..<equals])
            }
            let flagName = flag
            let value: () throws -> String = {
                if let inlineValue { return inlineValue }
                // `--task --driver x` is a missing value, not a task called "--driver". A prompt may start with
                // dashes; nothing else may.
                guard let next = remaining.first, !next.hasPrefix("--") || flagName == "-p" || flagName == "--prompt" else {
                    throw UsageError(message: "\(flagName) needs a value", usage: usage)
                }
                remaining = remaining.dropFirst()
                return next
            }
            switch flag {
            case "-h", "--help":
                throw UsageError(message: "", usage: usage)
            case "--json":
                options.json = true
            case "--sock":
                options.socket = try value()
            case "--home":
                options.home = try value()
            default:
                if try specific?(flag, value) == true { continue }
                if flag.hasPrefix("-") {
                    throw UsageError(message: "\(command): unknown option “\(flag)”", usage: usage)
                }
                guard let positional else {
                    throw UsageError(message: "\(command): unexpected argument “\(flag)”", usage: usage)
                }
                positional(argument)
            }
        }
        return options
    }
}
