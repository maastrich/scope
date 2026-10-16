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
      scope thread send <id> <text>       type <text> into it and press ↩ (--no-enter to leave it on the line);
                                          from a thread, the message says which thread sent it
      scope thread read <id>              the last lines of its terminal (-n/--lines <count>, --cursor <line>);
                                          --reply for the agent's last answer alone
      scope thread wait <id>...           block until the threads finish their turn or need someone, then print
                                          their state and last answer (--any for the first one, --timeout <s>)
      scope task new <prompt> [options]   sandbox a task (branch + worktrees) and open its first thread
      scope task show <id|slug>           its whole brief, and what was kept when it was archived or closed: each
                                          thread's last answer and its report file (REPORT.md or --deliverable)
      scope task archive <id|slug>        put a finished task away: threads and processes stopped,
                                          uncommitted work saved, worktrees removed; branch kept
      scope task close <id|slug>          archive it, then forget it (--delete-branch to delete the branch too)
      scope task restore <id|slug>        bring an archived task back: worktrees rebuilt on its branches, the
                                          uncommitted work saved at archive put back (--scope for a shared slug)
      scope task rebase [<id|slug>]        bring a task up to date with main now: behind and clean, Scope rebases
                                          the sandbox and pushes with lease; conflicting, its thread is asked
                                          (default: the caller's own task; --scope for a shared slug)
      scope task topic [<id|slug>] <topic>
                                          file a task under a topic, or out of any with --clear (default: the
                                          caller's own task); the tasks it started follow unless --no-children
      scope gc                            clean up now what Scope cleans every 30 minutes (--dry-run to preview)
      scope config get [key]              settings Scope applies live: automation.maxAgentTasks, automation.maxAgentThreads
      scope config set <key> <value>      change one, as Settings would; from your own terminal only, never an agent's
      scope summary [period]              what was done over a period, scope by scope: tasks finished or dropped,
                                          their pull requests and briefs, agent time and time waiting on you
                                          (default: last 7 days)
      scope usage [period]                how Scope's own interface was used: top controls and commands, what was
                                          never used, keyboard vs menu vs palette, agent vs user calls (local log)
      scope mcp                           speak MCP on stdio, same commands
      scope ping                          check that Scope is listening

    thread new:
      --scope <slug|name|id|path>   which scope (default: the caller's, else the one holding the cwd)
      --driver <id>                 driver profile (default: the scope's usual one)
      --task <id|slug>              open it inside that task's sandbox (any scope; --scope settles a shared slug)
      --repo <relative/path>        open it in that repository
      --title <text>                row label
      -p, --prompt <text>           first thing the driver is asked
      --model <name>                model the driver runs on (default: yours for the same driver when you are a
                                    thread, else the scope's default, else the driver's in Settings)

    thread send:
      --no-enter                    leave the text on the line, without ↩
      --command                     a command for the driver itself (/model, /clear, /compact): typed verbatim,
                                    no line saying who sent it; agents may only command the threads they opened
                                    unless Settings ▸ Automation says otherwise

    task new:
      --scope <slug|name|id|path>   which scope
      --repo <relative/path>        repository to sandbox; repeat for several (default: proposed)
      --branch <name>               branch to create (default: proposed from the prompt, after the repository's
                                    convention); the scope/ prefix is reserved for Scope
      --pr <ref>                    start from that pull request's head: 123, #123, owner/repo#123 or its URL
                                    (default: a pull request the prompt asks to work on — "review #123" —
                                    never one it only cites; an unresolvable one is then ignored)
      --title <text>                task name (default: proposed)
      --slug <name>                 sandbox folder name (default: from the title)
      --driver <id>                 driver for the first thread
      --model <name>                model of the first thread (same defaults as thread new)
      --topic <text>                file it under a topic (default: the topic of the caller's own task)
      --deliverable <path>          the file the work ends in, relative to the task root or a sandbox; kept with
                                    the threads' last answers at archive (REPORT.md is kept anyway)
      --dry-run                     print the proposal, create nothing
      --no-thread                   create the task without opening a thread
      --no-setup                    skip the repositories' setup commands (.env files are still copied)

    list:
      --scope <slug|name|id|path>   only that scope

    summary:
      [period]                      today, yesterday, this week, last week, this month, last month,
                                    last 14 days, 2w, 2026-10-01, 2026-10, 2026-10-01..2026-10-14,
                                    since 2026-10-01 (weeks start on Monday)
      --scope <slug|name|id>        only that scope
      --task <id|slug>              one task: its whole brief, every thread and their kept answers, whatever
                                    the period

    usage:
      [period]                      same words as summary (default: last 7 days)
      --area <name>                 one area only: sidebar, inspector, sheet, command, palette, control, …
      --limit <n>                   rows per list (default: 20)

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
        case "gc":
            var parameters = GCParams()
            let shared = try options(&rest, command: "gc", specific: { flag, _ in
                guard flag == "--dry-run" else { return false }
                parameters.dryRun = true
                return true
            })
            return .call(.gc(parameters), shared)
        case "summary":
            var words: [String] = []
            var parameters = SummaryParams()
            let shared = try options(&rest, command: "summary", positional: { words.append($0) }, specific: { flag, value in
                switch flag {
                case "--scope": parameters.scope = try value()
                case "--task": parameters.task = try value()
                default: return false
                }
                return true
            })
            if !words.isEmpty {
                let period = words.joined(separator: " ")
                // Checked here for the usage error; the app parses it again against its own clock.
                guard ActivityPeriod.parse(period) != nil else {
                    throw UsageError(message: "summary: no period called “\(period)”. Try: \(ActivityPeriod.grammar)", usage: usage)
                }
                parameters.period = period
            }
            return .call(.summary(parameters), shared)
        case "usage":
            var words: [String] = []
            var parameters = UsageParams()
            let shared = try options(&rest, command: "usage", positional: { words.append($0) }, specific: { flag, value in
                switch flag {
                case "--area": parameters.area = try value()
                case "--limit":
                    let text = try value()
                    guard let limit = Int(text), limit > 0 else {
                        throw UsageError(message: "usage: --limit takes a positive number, not “\(text)”", usage: usage)
                    }
                    parameters.limit = limit
                default: return false
                }
                return true
            })
            if !words.isEmpty {
                let period = words.joined(separator: " ")
                guard ActivityPeriod.parse(period) != nil else {
                    throw UsageError(message: "usage: no period called “\(period)”. Try: \(ActivityPeriod.grammar)", usage: usage)
                }
                parameters.period = period
            }
            return .call(.usage(parameters), shared)
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
                var command = false
                let shared = try options(&rest, command: "thread send", positional: { words.append($0) }, specific: { flag, _ in
                    switch flag {
                    case "--no-enter": submit = false
                    case "--command": command = true
                    default: return false
                    }
                    return true
                })
                guard words.count >= 2 else { throw UsageError(message: "thread send takes a thread id and the text to type", usage: usage) }
                return .call(.threadSend(ThreadSendParams(thread: words[0], text: words.dropFirst().joined(separator: " "),
                                                          submit: submit, command: command)), shared)
            case "read":
                var words: [String] = []
                var parameters = ThreadReadParams(thread: "")
                let shared = try options(&rest, command: "thread read", positional: { words.append($0) }, specific: { flag, value in
                    switch flag {
                    case "-n", "--lines": parameters.lines = try count(try value(), flag: flag)
                    case "--cursor": parameters.cursor = try count(try value(), flag: flag)
                    case "--reply": parameters.view = .reply
                    default: return false
                    }
                    return true
                })
                guard words.count == 1 else { throw UsageError(message: "thread read takes one thread id", usage: usage) }
                parameters.thread = words[0]
                return .call(.threadRead(parameters), shared)
            case "wait":
                var parameters = ThreadWaitParams(threads: [])
                let shared = try options(&rest, command: "thread wait", positional: { parameters.threads.append($0) }, specific: { flag, value in
                    switch flag {
                    case "--any": parameters.until = .any
                    case "--timeout": parameters.timeout = try count(try value(), flag: flag)
                    default: return false
                    }
                    return true
                })
                guard !parameters.threads.isEmpty else { throw UsageError(message: "thread wait takes one thread id or more", usage: usage) }
                return .call(.threadWait(parameters), shared)
            case "new":
                break
            default:
                throw UsageError(message: "thread commands: new, stop, close, send, read, wait", usage: usage)
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
                case "--model": parameters.model = try value()
                default: return false
                }
                return true
            })
            return .call(.threadNew(parameters), shared)
        case "config":
            var words: [String] = []
            let shared = try options(&rest, command: "config", positional: { words.append($0) })
            switch words.first {
            case "get":
                guard words.count <= 2 else { throw UsageError(message: "config get takes at most one key", usage: usage) }
                return .call(.configGet(ConfigGetParams(key: words.dropFirst().first)), shared)
            case "set":
                guard words.count == 3 else { throw UsageError(message: "config set takes a key and a value", usage: usage) }
                return .call(.configSet(ConfigSetParams(key: words[1], value: words[2])), shared)
            default:
                throw UsageError(message: "config commands: get, set", usage: usage)
            }
        case "task":
            let sub = rest.first
            rest = rest.dropFirst()
            if sub == "show" {
                var words: [String] = []
                let shared = try options(&rest, command: "task show", positional: { words.append($0) })
                guard words.count == 1 else { throw UsageError(message: "task show takes one task id or slug", usage: usage) }
                return .call(.taskShow(TaskShowParams(task: words[0])), shared)
            }
            if sub == "archive" {
                var words: [String] = []
                let shared = try options(&rest, command: "task archive", positional: { words.append($0) })
                guard words.count == 1 else { throw UsageError(message: "task archive takes one task id or slug", usage: usage) }
                return .call(.taskArchive(TaskArchiveParams(task: words[0])), shared)
            }
            if sub == "close" {
                var words: [String] = []
                var parameters = TaskCloseParams(task: "")
                let shared = try options(&rest, command: "task close", positional: { words.append($0) }, specific: { flag, _ in
                    switch flag {
                    case "--delete-branch": parameters.deleteBranch = true
                    // Accepted from older scripts; a close no longer refuses anything, so there is nothing to force.
                    case "--force": break
                    default: return false
                    }
                    return true
                })
                guard words.count == 1 else { throw UsageError(message: "task close takes one task id or slug", usage: usage) }
                parameters.task = words[0]
                return .call(.taskClose(parameters), shared)
            }
            if sub == "restore" {
                var words: [String] = []
                var scope: String?
                let shared = try options(&rest, command: "task restore", positional: { words.append($0) }, specific: { flag, value in
                    guard flag == "--scope" else { return false }
                    scope = try value()
                    return true
                })
                guard words.count == 1 else { throw UsageError(message: "task restore takes one task id or slug", usage: usage) }
                return .call(.taskRestore(TaskRestoreParams(task: words[0], scope: scope)), shared)
            }
            if sub == "rebase" {
                var words: [String] = []
                var scope: String?
                let shared = try options(&rest, command: "task rebase", positional: { words.append($0) }, specific: { flag, value in
                    guard flag == "--scope" else { return false }
                    scope = try value()
                    return true
                })
                guard words.count <= 1 else { throw UsageError(message: "task rebase takes at most one task id or slug", usage: usage) }
                return .call(.taskRebase(TaskRebaseParams(task: words.first, scope: scope)), shared)
            }
            if sub == "topic" {
                var words: [String] = []
                var clear = false
                var children = true
                let shared = try options(&rest, command: "task topic", positional: { words.append($0) }, specific: { flag, _ in
                    switch flag {
                    case "--clear": clear = true
                    case "--no-children": children = false
                    default: return false
                    }
                    return true
                })
                // The last word is the topic, the one before it the task; without a task, the caller's own. An empty
                // topic is refused rather than read as a clear: taking a task out of its group is said out loud.
                if clear {
                    guard words.count <= 1 else {
                        throw UsageError(message: "task topic --clear takes at most a task id or slug, no topic", usage: usage)
                    }
                    return .call(.taskTopic(TaskTopicParams(task: words.first, topic: nil, children: children)), shared)
                }
                guard (1...2).contains(words.count), let topic = words.last, topic.contains(where: { !$0.isWhitespace }) else {
                    throw UsageError(message: "task topic takes a topic, after the task id or slug (or --clear)", usage: usage)
                }
                return .call(.taskTopic(TaskTopicParams(task: words.count == 2 ? words[0] : nil, topic: topic,
                                                        children: children)), shared)
            }
            guard sub == "new" else {
                throw UsageError(message: "task commands: new, show, archive, close, restore, topic", usage: usage)
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
                case "--model": parameters.model = try value()
                case "--topic": parameters.topic = try value()
                case "--pr": parameters.startPR = try value()
                case "--deliverable": parameters.deliverable = try value()
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

    /// A non-negative whole number, or a usage error naming the flag.
    private static func count(_ text: String, flag: String) throws -> Int {
        guard let value = Int(text), value >= 0 else {
            throw UsageError(message: "\(flag) takes a whole number, not “\(text)”", usage: usage)
        }
        return value
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
