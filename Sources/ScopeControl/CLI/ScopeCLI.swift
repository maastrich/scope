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
    /// `a,b,c` or `a b c`, as `--models` is typed.
    static func list(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    public struct UsageError: Error, Sendable, Equatable, CustomStringConvertible {
        public var message: String
        public var usage: String
        public var description: String { "\(message)\n\n\(usage)" }
    }

    public static let usage = """
    usage: scope <command> [options]

      scope list [scopes|threads|tasks]   what Scope is holding right now, each task with its pull request
      scope thread new [options]          open a thread and print its id
      scope thread stop <id>              stop the thread's process (the row stays)
      scope thread close <id>             hang it up and remove it
      scope thread send <id> <text>       type <text> into it and press ↩ (--no-enter to leave it on the line);
                                          from a thread, the message says which thread sent it; --wait then
                                          waits for its answer as thread wait would (--timeout <s>)
      scope thread read <id>              the last lines of its terminal (-n/--lines <count>, --cursor <line>);
                                          --reply for the agent's last answer alone
      scope thread wait <id>...           block until the threads finish their turn or need someone, then print
                                          their state, last answer and pull request (--any for the first one,
                                          --timeout <s>); a sub-agent still running in the background holds it
      scope task new <prompt> [options]   sandbox a task (branch + worktrees) and open its first thread;
                                          @task:<slug> / @thread:<id> in a prompt or a message is replaced by
                                          that task's or thread's context (brief, branch, PR, last answer)
      scope task show <id|slug>           its whole brief, and what was kept when it was archived or closed: each
                                          thread's last answer and its report file (REPORT.md or --deliverable)
      scope task archive <id|slug>        put a finished task away: threads and processes stopped,
                                          uncommitted work saved, worktrees removed; branch kept (--scope for
                                          a shared slug)
      scope task close <id|slug>          archive it, then forget it (--delete-branch to delete the branch too;
                                          --scope for a shared slug)
      scope task restore <id|slug>        bring an archived task back: worktrees rebuilt on its branches, the
                                          uncommitted work saved at archive put back (--scope for a shared slug)
      scope task rebase [<id|slug>]        bring a task up to date with main now: behind and clean, Scope rebases
                                          the sandbox and pushes with lease; conflicting, its thread is asked
                                          (default: the caller's own task; --scope for a shared slug)
      scope task try <id|slug>            run the task's branch in your own checkout: uncommitted changes stashed,
                                          HEAD detached onto the branch (--refresh to follow the branch's new head,
                                          --end to put the checkout back; --scope for a shared slug). Your own
                                          terminal only, never an agent's; Settings › Tasks must allow it
      scope task checkpoints [<id|slug>]  the task's checkpoints: one snapshot of its sandboxes per turn that
                                          changed a file (default: the caller's own task; --scope for a shared slug)
      scope task restore-checkpoint [<id|slug>] <n>
                                          put checkpoint <n>'s files back into the sandboxes; branch and commits
                                          stay, the state replaced is checkpointed first (agents: own task only)
      scope task topic [<id|slug>] <topic>
                                          file a task under a topic, or out of any with --clear (default: the
                                          caller's own task); the tasks it started follow unless --no-children
      scope task milestone add [<id|slug>] <title>
                                          name a milestone on a mission (default: the caller's own task);
                                          --validate <command> is run in its sandbox when it is marked done,
                                          --child <id|slug> names the task doing it
      scope task milestone done [<id|slug>] <n|title>
                                          mark a milestone done: Scope runs its validation and records the
                                          verdict; a failure goes to the milestone's thread (--child <id|slug>)
      scope schedule list                 the scheduled prompts of every scope (--scope for one): rule, target,
                                          next fire, last run
      scope schedule run <name>           fire a schedule now, whatever its rule says (--scope for a shared name)
      scope gc                            clean up now what Scope cleans every 30 minutes (--dry-run to preview)
      scope release [X.Y.Z]               cut a release of a repository: Scope clones its default branch under its
                                          own home and runs scripts/release.sh there (else tags and pushes), with
                                          your git identity, outside any sandbox; refused unless CI on the head
                                          is green (--force) and no release is already running (--dry-run, --repo)
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
      --driver <id>                 driver profile (default: the one chosen in Settings, never yours)
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
      --wait                        once submitted, wait for the thread's answer and print it, as thread wait
                                    does (one call instead of send then wait)
      --timeout <s>                 seconds the wait may take (default 600)

    task new:
      --scope <slug|name|id|path>   which scope
      --repo <relative/path>        repository to sandbox; repeat for several (default: proposed)
      --branch <name>               branch to create (default: proposed from the prompt, after the repository's
                                    convention); the scope/ prefix is reserved for Scope
      --pr <ref>                    start from that pull request's head: 123, #123, owner/repo#123 or its URL
                                    (default: a pull request the prompt asks to work on — "review #123" —
                                    never one it only cites; an unresolvable one is then ignored)
      --issue <ref>                 work on that GitHub issue: 123, #123, owner/repo#123 or its URL; its title,
                                    body and labels open the brief, the task records it (default: an issue the
                                    prompt asks to work on — "fix #123", an issue URL — never one it only cites)
      --title <text>                task name (default: proposed)
      --slug <name>                 sandbox folder name (default: from the title)
      --driver <id>                 driver for the first thread (default: the one chosen in Settings)
      --model <name>                model of the first thread (same defaults as thread new)
      --topic <text>                file it under a topic (default: the topic of the caller's own task)
      --deliverable <path>          the file the work ends in, relative to the task root or a sandbox; kept with
                                    the threads' last answers at archive (REPORT.md is kept anyway)
      --attempts <n>                run the brief n ways (2–9): n sibling tasks under one topic, branches
                                    <branch>-a1..n, to compare in Scope and keep one; each counts against the
                                    agents' task budget
      --models <a,b,c>              with --attempts: one model for all, or one per attempt
      --drivers <x,y,z>             with --attempts: one driver for all, or one per attempt
      --mission                     a mission: the prompt is a goal; the context file asks the agent to split it
                                    into milestones, one child task at a time, each validated before the next
      --dry-run                     print the proposal, create nothing
      --no-thread                   create the task without opening a thread
      --no-setup                    skip the repositories' setup commands (.env files are still copied)

    list:
      --scope <slug|name|id|path>   only that scope

    release:
      [X.Y.Z]                       the version to release (default: the next one from Conventional Commits,
                                    as scripts/release.sh or `git cliff --bumped-version` computes it)
      --repo <relative/path>        which repository (default: your task's, or the one holding your cwd, or the
                                    scope's only one)
      --scope <slug|name|id|path>   which scope
      --dry-run                     clone, check, print the notes and the plan; publish nothing
      --force                       release although CI on the head is red, still running or absent

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
        case "release":
            var words: [String] = []
            var parameters = ReleaseParams()
            let shared = try options(&rest, command: "release", positional: { words.append($0) }, specific: { flag, value in
                switch flag {
                case "--dry-run": parameters.dryRun = true
                case "--force": parameters.force = true
                case "--repo": parameters.repo = try value()
                case "--scope": parameters.scope = try value()
                default: return false
                }
                return true
            })
            guard words.count <= 1 else { throw UsageError(message: "release takes at most one version", usage: usage) }
            if let word = words.first {
                let version = word.hasPrefix("v") ? String(word.dropFirst()) : word
                guard ReleaseVersion.isValid(version) else {
                    throw UsageError(message: "“\(word)” is not a version: expected X.Y.Z or X.Y.Z-pre.N", usage: usage)
                }
                parameters.version = version
            }
            return .call(.release(parameters), shared)
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
                var wait = false
                var timeout: Int?
                let shared = try options(&rest, command: "thread send", positional: { words.append($0) }, specific: { flag, value in
                    switch flag {
                    case "--no-enter": submit = false
                    case "--command": command = true
                    case "--wait": wait = true
                    case "--timeout": timeout = try count(try value(), flag: flag)
                    default: return false
                    }
                    return true
                })
                guard words.count >= 2 else { throw UsageError(message: "thread send takes a thread id and the text to type", usage: usage) }
                guard submit || !wait else { throw UsageError(message: "--wait needs the text submitted: drop --no-enter", usage: usage) }
                return .call(.threadSend(ThreadSendParams(thread: words[0], text: words.dropFirst().joined(separator: " "),
                                                          submit: submit, command: command, wait: wait, timeout: timeout)), shared)
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
        case "schedule":
            let sub = rest.first
            rest = rest.dropFirst()
            switch sub {
            case "list":
                var scope: String?
                let shared = try options(&rest, command: "schedule list", specific: { flag, value in
                    guard flag == "--scope" else { return false }
                    scope = try value()
                    return true
                })
                return .call(.scheduleList(ScheduleListParams(scope: scope)), shared)
            case "run":
                var words: [String] = []
                var scope: String?
                let shared = try options(&rest, command: "schedule run", positional: { words.append($0) }, specific: { flag, value in
                    guard flag == "--scope" else { return false }
                    scope = try value()
                    return true
                })
                guard words.count == 1 else { throw UsageError(message: "schedule run takes one schedule name", usage: usage) }
                return .call(.scheduleRun(ScheduleRunParams(name: words[0], scope: scope)), shared)
            default:
                throw UsageError(message: "schedule commands: list, run", usage: usage)
            }
        case "task":
            let sub = rest.first
            rest = rest.dropFirst()
            if sub == "milestone" {
                let verb = rest.first
                rest = rest.dropFirst()
                var words: [String] = []
                var validation: String?
                var child: String?
                let shared = try options(&rest, command: "task milestone", positional: { words.append($0) }, specific: { flag, value in
                    switch flag {
                    case "--validate", "--validation": validation = try value()
                    case "--child": child = try value()
                    default: return false
                    }
                    return true
                })
                // The last word is the milestone, the one before it the task; without a task, the caller's own.
                guard (1...2).contains(words.count), let last = words.last, last.contains(where: { !$0.isWhitespace }) else {
                    throw UsageError(message: "task milestone \(verb ?? "") takes a milestone, after the task id or slug", usage: usage)
                }
                let task = words.count == 2 ? words[0] : nil
                switch verb {
                case "add":
                    return .call(.milestoneAdd(MilestoneAddParams(task: task, title: last, validation: validation, child: child)), shared)
                case "done":
                    guard validation == nil else { throw UsageError(message: "task milestone done takes no --validate", usage: usage) }
                    return .call(.milestoneDone(MilestoneDoneParams(task: task, milestone: last, child: child)), shared)
                default:
                    throw UsageError(message: "task milestone commands: add, done", usage: usage)
                }
            }
            if sub == "show" {
                var words: [String] = []
                let shared = try options(&rest, command: "task show", positional: { words.append($0) })
                guard words.count == 1 else { throw UsageError(message: "task show takes one task id or slug", usage: usage) }
                return .call(.taskShow(TaskShowParams(task: words[0])), shared)
            }
            if sub == "archive" {
                var words: [String] = []
                var scope: String?
                let shared = try options(&rest, command: "task archive", positional: { words.append($0) }, specific: { flag, value in
                    guard flag == "--scope" else { return false }
                    scope = try value()
                    return true
                })
                guard words.count == 1 else { throw UsageError(message: "task archive takes one task id or slug", usage: usage) }
                return .call(.taskArchive(TaskArchiveParams(task: words[0], scope: scope)), shared)
            }
            if sub == "close" {
                var words: [String] = []
                var parameters = TaskCloseParams(task: "")
                let shared = try options(&rest, command: "task close", positional: { words.append($0) }, specific: { flag, value in
                    switch flag {
                    case "--delete-branch": parameters.deleteBranch = true
                    case "--scope": parameters.scope = try value()
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
            if sub == "try" {
                var words: [String] = []
                var scope: String?
                var end = false
                var refresh = false
                let shared = try options(&rest, command: "task try", positional: { words.append($0) }, specific: { flag, value in
                    switch flag {
                    case "--scope": scope = try value()
                    case "--end": end = true
                    case "--refresh": refresh = true
                    default: return false
                    }
                    return true
                })
                guard words.count == 1 else { throw UsageError(message: "task try takes one task id or slug", usage: usage) }
                guard !(end && refresh) else { throw UsageError(message: "task try takes --end or --refresh, not both", usage: usage) }
                return .call(.taskTry(TaskTryParams(task: words[0], scope: scope, end: end, refresh: refresh)), shared)
            }
            if sub == "checkpoints" {
                var words: [String] = []
                var scope: String?
                let shared = try options(&rest, command: "task checkpoints", positional: { words.append($0) }, specific: { flag, value in
                    guard flag == "--scope" else { return false }
                    scope = try value()
                    return true
                })
                guard words.count <= 1 else { throw UsageError(message: "task checkpoints takes at most one task id or slug", usage: usage) }
                return .call(.taskCheckpoints(TaskCheckpointsParams(task: words.first, scope: scope)), shared)
            }
            if sub == "restore-checkpoint" {
                var words: [String] = []
                var scope: String?
                let shared = try options(&rest, command: "task restore-checkpoint", positional: { words.append($0) }, specific: { flag, value in
                    guard flag == "--scope" else { return false }
                    scope = try value()
                    return true
                })
                // The last word is the number, the one before it the task; without a task, the caller's own.
                guard (1...2).contains(words.count), let number = words.last.flatMap({ Int($0) }), number > 0 else {
                    throw UsageError(message: "task restore-checkpoint takes a checkpoint number, after the task id or slug", usage: usage)
                }
                return .call(.taskRestoreCheckpoint(TaskRestoreCheckpointParams(task: words.count == 2 ? words[0] : nil, number: number,
                                                                                 scope: scope)), shared)
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
                throw UsageError(message: "task commands: new, show, archive, close, restore, rebase, checkpoints, restore-checkpoint, topic, milestone", usage: usage)
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
                case "--issue": parameters.issue = try value()
                case "--deliverable": parameters.deliverable = try value()
                case "--attempts":
                    let raw = try value()
                    guard let count = Int(raw), count >= 1 else {
                        throw UsageError(message: "--attempts takes a number of attempts, got “\(raw)”", usage: usage)
                    }
                    parameters.attempts = count
                case "--models": parameters.models += Self.list(try value())
                case "--drivers": parameters.drivers += Self.list(try value())
                case "-p", "--prompt": prompt.append(try value())
                case "--dry-run": parameters.dryRun = true
                case "--no-thread": parameters.openThread = false
                case "--no-setup": parameters.runSetup = false
                case "--mission": parameters.mission = true
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
