import Foundation
import ScopeCore

/// Turns a result into what the terminal shows. Pure, so what the CLI prints is under test.
///
/// The text is meant to be read by a person *and* piped: one record per line, columns padded, no colour, no
/// box drawing. Anything that wants structure asks for `--json`.
public enum CLIRenderer {
    /// `--json`: the result object, pretty-printed.
    public static func json(_ payload: ControlResultPayload) throws -> String {
        let encoder = ControlProtocol.makeEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        let data: Data = switch payload {
        case .ping(let result): try encoder.encode(result)
        case .list(let result): try encoder.encode(result)
        case .thread(let result): try encoder.encode(result)
        case .task(let result): try encoder.encode(result)
        case .action(let result, _): try encoder.encode(result)
        case .read(let result): try encoder.encode(result)
        case .wait(let result): try encoder.encode(result)
        case .summary(let result): try encoder.encode(result)
        case .taskShow(let result): try encoder.encode(result)
        case .taskCheckpoints(let result): try encoder.encode(result)
        case .usage(let result): try encoder.encode(result)
        case .release(let result): try encoder.encode(result)
        case .schedules(let result): try encoder.encode(result)
        case .taskBranches(let result): try encoder.encode(result)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The default output.
    public static func text(_ payload: ControlResultPayload) -> String {
        switch payload {
        case .ping(let result):
            let automation = result.automation
            return """
            \(result.app) \(result.version), protocol \(result.rpc)
            home        \(result.home)
            methods     \(result.methods.joined(separator: ", "))
            automation  agents \(automation.agentsMayDrive ? "may drive" : "may not drive"), \
            threads \(automation.threads.rawValue), tasks \(automation.tasks.rawValue), \
            releases \(automation.releases.rawValue), reach \(automation.threadReach.rawValue)
            budget      \(automation.maxAgentTasks) open tasks, \(automation.maxAgentThreads) running threads\
            \(automation.depthLimit.map { ", depth ≤ \($0)" } ?? ", any depth")
            limits      \(result.limits.map { RateLimitText.line($0, now: .now) } ?? RateLimitText.unknown)
            """
        case .list(let result):
            var blocks: [String] = []
            if let limits = result.limits {
                blocks.append("limits  " + RateLimitText.line(limits, now: .now))
            }
            if !result.scopes.isEmpty {
                blocks.append(table(["SCOPE", "PATH", "REPOS"], result.scopes.map {
                    [$0.slug + ($0.status == "ok" ? "" : " (\($0.status))"), $0.path, "\($0.repos.count)"]
                }))
            }
            if !result.tasks.isEmpty {
                blocks.append(table(["TASK", "NAME", "SCOPE", "TOPIC", "BRANCH", "PR", "MAIN", "ROOT"], result.tasks.map {
                    [$0.slug + ($0.archivedAt == nil ? "" : " (archived)"), $0.name, $0.scopeSlug, $0.topic ?? "", $0.branch,
                     pullRequestColumn($0), mainColumn($0), $0.root]
                }))
            }
            if !result.threads.isEmpty {
                blocks.append(table(["THREAD", "TITLE", "DRIVER", "MODEL", "MODE", "STATE", "SCOPE", "TASK", "TOKENS", "BY", "ACTIVITY"], result.threads.map {
                    [$0.id, $0.title, $0.driver, $0.session?.model ?? $0.model ?? "", $0.session?.modeColumn ?? "", $0.state, $0.scopeSlug,
                     $0.task ?? "", $0.tokens ?? "", openedBy($0), activityColumn($0)]
                }))
            }
            return blocks.isEmpty ? "nothing yet" : blocks.joined(separator: "\n\n")
        case .thread(let result):
            var line = "thread \(result.thread) — \(result.title) [\(result.driver)\(result.model.map { " · \($0)" } ?? "")] in \(result.scopeSlug)"
            if let task = result.task { line += " · task \(task)" }
            return line + "\n\(result.cwd)"
        case .task(let result):
            var lines: [String] = []
            lines.append(result.created
                ? "task \(result.task ?? result.slug) — \(result.name)"
                : "would create the task “\(result.name)”")
            lines.append("branch      \(result.branch)")
            lines.append("slug        \(result.slug)")
            if let topic = result.topic { lines.append("topic       \(topic)") }
            if let root = result.root { lines.append("sandbox     \(root)") }
            for repo in result.repos {
                lines.append("repo        \(repo.repo) → \(repo.worktree)\(repo.branchCreated ? " (branch created)" : "")")
            }
            if let thread = result.thread { lines.append("thread      \(thread)") }
            if let issue = result.issue { lines.append("issue       \(issue)") }
            if let note = result.note { lines.append("note        \(note)") }
            if let attempts = result.attempts {
                lines.append("")
                lines.append(result.created ? "\(attempts.count) attempts, one task each:" : "would create \(attempts.count) attempts:")
                for attempt in attempts {
                    var line = "  \(attempt.index)  \(attempt.task ?? attempt.slug) — \(attempt.branch)"
                    if let driver = attempt.driver { line += " · \(driver)" }
                    if let model = attempt.model { line += " · \(model)" }
                    if let thread = attempt.thread { line += " · thread \(thread)" }
                    lines.append(line)
                }
            }
            if !result.created {
                lines.append("")
                lines.append("Nothing was written. Run it again without --dry-run to create it.")
            }
            return lines.joined(separator: "\n")
        case .action(let result, _):
            guard let wait = result.wait else { return result.message }
            return result.message + "\n\n" + text(.wait(wait))
        case .read(let result):
            var lines: [String]
            if result.source == ThreadReadParams.View.reply.rawValue {
                let at = result.replyAt.map { " at " + time($0) } ?? ""
                lines = ["thread \(result.thread) — \(result.title) · last reply\(at) (\(result.state))"]
                if result.staleReply == true { lines.append(staleNotice) }
            } else {
                let range = result.toLine > result.fromLine ? "lines \(result.fromLine)–\(result.toLine - 1)" : "no lines"
                lines = ["thread \(result.thread) — \(result.title) · \(range) (\(result.state))"]
            }
            if let note = result.note { lines.append(note) }
            lines += quoted(result.text)
            if let older = result.olderCursor {
                lines.append("older lines: cursor \(older) (scope thread read \(result.thread) --cursor \(older))")
            }
            return lines.joined(separator: "\n")
        case .wait(let result):
            var lines = [result.complete
                ? "done waiting after \(result.waited)s"
                : "still at work after \(result.waited)s: " + result.threads.filter { !$0.settled }.map(\.thread).joined(separator: ", ")]
            for entry in result.threads {
                lines.append("")
                var status = entry.state
                if !entry.settled { status += ", still at work" }
                if let agents = entry.agents { status += ": \(agents) sub-agent\(agents == 1 ? "" : "s") running in the background" }
                lines.append("thread \(entry.thread) — \(entry.title) (\(status))")
                if let pr = entry.pullRequest { lines.append("pull request \(pr.line) \(pr.url.absoluteString)" + (entry.task.map { " · task \($0)" } ?? "")) }
                if let reply = entry.reply {
                    lines.append("last reply" + (entry.replyAt.map { " at " + time($0) } ?? "") + ":")
                    if entry.staleReply == true { lines.append(staleNotice) }
                    lines += quoted(reply)
                }
            }
            return lines.joined(separator: "\n")
        case .summary(let result):
            return summary(result)
        case .taskShow(let result):
            return taskShow(result)
        case .taskCheckpoints(let result):
            return checkpoints(result)
        case .usage(let result):
            return usage(result)
        case .release(let result):
            return release(result)
        case .schedules(let result):
            return schedules(result)
        case .taskBranches(let result):
            return branches(result)
        }
    }

    /// `scope task branch list`: one line per worktree, the task's own marked, with its pull requests.
    static func branches(_ result: TaskBranchListResult) -> String {
        let rows = result.worktrees.map { entry -> [String] in
            let prs = (entry.pullRequests ?? []).map { $0.line(named: false) }.joined(separator: " · ")
            return [RepoName.display(entry.repo), entry.branch, entry.primary ? "task branch" : (entry.base.map { "from \($0)" } ?? ""),
                    prs, entry.worktree]
        }
        return table(["REPO", "BRANCH", "", "PR", "WORKTREE"], rows)
            + "\n\nscope task branch add \(result.slug) <branch> [--repo R] [--from <ref>|--pr <ref>] adds one; "
            + "scope thread new --task \(result.slug) --branch <branch> opens a thread in it."
    }

    /// One row per schedule: where it fires next, and what its last run said.
    static func schedules(_ result: ScheduleListResult) -> String {
        guard !result.schedules.isEmpty else { return "no schedules; add one in Settings ▸ Automation ▸ Schedules" }
        return table(["SCHEDULE", "SCOPE", "RULE", "TARGET", "NEXT", "LAST RUN"], result.schedules.map { schedule in
            let last: String
            if let at = schedule.lastRunAt {
                last = time(at) + (schedule.lastOutcome.map { " · \($0)" } ?? "") + (schedule.lastSummary.map { " — \($0.prefix(60))" } ?? "")
            } else {
                last = "never"
            }
            return [schedule.name + (schedule.enabled ? "" : " (paused)"), schedule.scopeSlug, schedule.rule, schedule.target,
                    schedule.next.map(time) ?? "", last]
        })
    }

    /// What happened, then the script's own words: it already says what it fetched, planned and pushed.
    static func release(_ result: ReleaseResult) -> String {
        var lines: [String] = []
        let what = result.tag ?? "a release"
        if result.dryRun {
            lines.append("dry run of \(what) for \(result.repo) in \(result.scopeSlug): nothing was pushed")
        } else if result.released {
            lines.append("released \(what) of \(result.repo) in \(result.scopeSlug)")
        } else {
            lines.append("the release of \(result.repo) in \(result.scopeSlug) did not go through")
        }
        lines.append("head        \(result.branch) @ \(result.head.prefix(12))")
        if let ci = result.ci { lines.append("ci          \(ci)") }
        lines.append("method      \(result.method)")
        lines.append("checkout    \(result.checkout)")
        if !result.output.isEmpty {
            lines.append("")
            if result.truncated { lines.append("[… output cut, its end follows]") }
            lines.append(result.output.trimmingCharacters(in: .newlines))
        }
        return lines.joined(separator: "\n")
    }

    /// `scope task checkpoints`: one line per checkpoint, newest last, with the undo ones marked.
    static func checkpoints(_ result: TaskCheckpointsResult) -> String {
        guard !result.checkpoints.isEmpty else { return "no checkpoint yet for \(result.slug): one is taken when a turn changes a file" }
        let rows = result.checkpoints.map { entry -> [String] in
            let who = entry.reason == "before_restore" ? "before restore" : (entry.threadTitle ?? entry.thread ?? "")
            let turn = entry.turn.map(String.init) ?? ""
            var delta = ""
            if entry.additions > 0 { delta += "+\(entry.additions)" }
            if entry.deletions > 0 { delta += (delta.isEmpty ? "" : " ") + "-\(entry.deletions)" }
            return [String(entry.number), time(entry.at), who, turn, delta, entry.said ?? ""]
        }
        return table(["N", "AT", "THREAD", "TURN", "DELTA", "SAID"], rows)
            + "\n\nscope task restore-checkpoint \(result.slug) <N> puts one back; the state replaced is checkpointed first."
    }

    /// One block per scope, a line per task with the start of its brief under it, the threads outside tasks, then what
    /// the summary cannot know. Dates are days in the period's time zone.
    static func summary(_ result: SummaryResult) -> String {
        let zone = TimeZone(identifier: result.period.timeZone) ?? .current
        func day(_ date: Date) -> String {
            date.formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day())
        }
        let lastDay = result.period.until.addingTimeInterval(-1)
        let span = day(result.period.since) == day(lastDay) ? day(lastDay) : "\(day(result.period.since)) → \(day(lastDay))"
        var lines = ["\(result.period.label): \(span) (\(result.period.timeZone))"]

        func taskLines(_ task: SummaryResult.Task, indent: String) -> [String] {
            var parts = ["\(task.name) [\(task.slug)]"]
            let named = task.pullRequests.count > 1
            for pr in task.pullRequests {
                parts.append((named ? pr.repo.map { "\(RepoName.display($0)) " } ?? "" : "") + "#\(pr.number)" + (pr.state.map { " \($0)" } ?? " (state unknown)"))
            }
            var when = "created \(day(task.createdAt))"
            if let closed = task.closedAt { when += ", closed \(day(closed))" }
            else if let archived = task.archivedAt { when += ", archived \(day(archived))" }
            else { when += ", last active \(day(task.lastActivity))" }
            parts.append(when)
            if !task.threads.isEmpty { parts.append("\(task.threads.count) thread\(task.threads.count == 1 ? "" : "s")") }
            if let tokens = task.tokens { parts.append("\(TokenUsageText.compact(tokens)) tokens all told") }
            if let time = timeSpent(task) { parts.append(time) }
            if task.createdByAgent { parts.append("by an agent") }
            var out = [indent + task.outcome.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0) + parts.joined(separator: " · ")]
            if let brief = task.brief { out.append(indent + String(repeating: " ", count: 10) + brief) }
            if let answer = task.answer { out.append(indent + String(repeating: " ", count: 10) + "→ " + ThreadTranscript.defused(answer)) }
            if let reports = task.reports { out.append(indent + String(repeating: " ", count: 10) + "kept: " + reports.joined(separator: ", ")) }
            return out
        }
        func timeSpent(_ task: SummaryResult.Task) -> String? {
            guard let agent = task.agentSeconds else { return nil }
            return "agent \(DurationText.short(agent)), waited on you \(DurationText.short(task.waitingSeconds ?? 0))"
        }
        func threadLine(_ thread: SummaryResult.Thread) -> String {
            var line = "\(thread.id)  \(thread.title) [\(thread.driver)] · opened \(day(thread.createdAt))"
            if let closed = thread.closedAt { line += ", closed \(day(closed))" }
            else if let launched = thread.lastLaunchedAt { line += ", last launched \(day(launched))" }
            if let tokens = thread.tokens { line += " · \(TokenUsageText.compact(tokens)) tokens all told" }
            return line
        }

        if let detail = result.detail {
            let task = detail.task
            lines = ["task \(task.slug) — \(task.name) (\(detail.scope))"]
            lines.append("outcome     \(task.outcome.rawValue)")
            lines.append("branch      \(task.branch)" + (task.repos.isEmpty ? "" : " in " + task.repos.joined(separator: ", ")))
            if let topic = task.topic { lines.append("topic       \(topic)") }
            lines += pullRequestLines(task.pullRequests)
            lines.append("created     \(day(task.createdAt))" + (task.createdByAgent ? " by an agent" : ""))
            if let tokens = task.tokens { lines.append("tokens      \(TokenUsageText.compact(tokens))") }
            if let archived = task.archivedAt { lines.append("archived    \(day(archived))") }
            if let closed = task.closedAt { lines.append("closed      \(day(closed))") }
            if let time = timeSpent(task) { lines.append("time        " + time) }
            for thread in task.threads { lines.append("thread      " + threadLine(thread)) }
            if let reports = task.reports { lines.append("kept        " + reports.joined(separator: ", ") + " (scope task show \(task.slug))") }
            if let prompt = detail.prompt { lines += ["", "brief:", prompt] }
            for reply in detail.replies ?? [] {
                lines += ["", "last answer of \(reply.title) [\(reply.driver)] at \(time(reply.at)):"]
                lines += quoted(ThreadTranscript.defused(reply.text))
            }
            return lines.joined(separator: "\n")
        }

        if result.scopes.isEmpty { lines += ["", "nothing in this period"] }
        for scope in result.scopes {
            let counts = TaskOutcome.allCases.compactMap { outcome -> String? in
                let count = switch outcome {
                case .merged: scope.counts.merged
                case .delivered: scope.counts.delivered
                case .abandoned: scope.counts.abandoned
                case .archived: scope.counts.archived
                case .active: scope.counts.active
                }
                return count == 0 ? nil : "\(count) \(outcome.rawValue)"
            }
            var header = "\(scope.slug)\(scope.declared ? "" : " (no longer declared)") — \(scope.counts.total) task\(scope.counts.total == 1 ? "" : "s")"
            if !counts.isEmpty { header += ": " + counts.joined(separator: ", ") }
            if !scope.threads.isEmpty { header += " · \(scope.threads.count) thread\(scope.threads.count == 1 ? "" : "s") outside tasks" }
            lines += ["", header]
            var topic: String??
            for task in scope.tasks {
                if topic == nil || topic! != task.topic {
                    topic = .some(task.topic)
                    if let name = task.topic { lines.append("  topic: \(name)") }
                    else if scope.tasks.contains(where: { $0.topic != nil }) { lines.append("  no topic") }
                }
                lines += taskLines(task, indent: "    ")
            }
            if !scope.threads.isEmpty {
                lines.append("  outside tasks")
                lines += scope.threads.map { "    " + threadLine($0) }
            }
        }
        lines += [""] + result.limits.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    /// `pr          api #12 Title (open) https://…`, one per pull request; `prs         2 · 1 merged · 1 open` first
    /// when there are several, so the count is read before the lines.
    static func pullRequestLines(_ pullRequests: [SummaryResult.PullRequest]) -> [String] {
        var lines: [String] = []
        let named = pullRequests.count > 1
        if named {
            let states = Dictionary(grouping: pullRequests, by: { $0.state ?? "state unknown" }).mapValues(\.count)
            let counts = ["open", "merged", "closed", "state unknown"].compactMap { state in states[state].map { "\($0) \(state)" } }
            lines.append("prs         \(pullRequests.count) · " + counts.joined(separator: " · "))
        }
        for pr in pullRequests {
            let repo = named ? pr.repo.map { "\(RepoName.display($0)) " } ?? "" : ""
            lines.append("pr          \(repo)#\(pr.number) \(pr.title) (\(pr.state ?? "state unknown")) \(pr.url.absoluteString)")
        }
        return lines
    }

    /// `scope task show`: the task's facts, its whole brief, then each report file and each thread's last answer,
    /// fenced as agent output.
    static func taskShow(_ result: TaskShowResult) -> String {
        let task = result.task
        var lines = ["task \(task.slug) — \(task.name) (\(result.scope))"]
        lines.append("outcome     \(task.outcome.rawValue)")
        lines.append("branch      \(task.branch)" + (task.repos.isEmpty ? "" : " in " + task.repos.joined(separator: ", ")))
        if let lives = result.pullRequests ?? result.pullRequest.map({ [$0] }), !lives.isEmpty {
            // What GitHub last said of each, over what the record keeps.
            let named = lives.count > 1
            if named { lines += pullRequestLines(task.pullRequests).prefix(1) }
            for live in lives {
                lines.append("pr          \(live.line(named: named))" + (live.title.map { " — \($0)" } ?? "") + " \(live.url.absoluteString)")
            }
        } else {
            lines += pullRequestLines(task.pullRequests)
        }
        lines.append("created     \(time(task.createdAt))")
        if let archived = task.archivedAt { lines.append("archived    \(time(archived))") }
        if let closed = task.closedAt { lines.append("closed      \(time(closed))") }
        lines += ["", "brief:", result.prompt ?? "(none)"]
        if let deliverable = result.deliverable {
            for file in deliverable.files {
                lines += ["", "\(file.name)" + (file.truncated ? " (cut at \(TaskDeliverable.fileLimit / 1024) KB)" : "") + ":"]
                lines += quoted(ThreadTranscript.defused(file.text))
            }
            for reply in deliverable.replies {
                lines += ["", "last answer of \(reply.title) [\(reply.driver)] at \(time(reply.at)):"]
                lines += quoted(ThreadTranscript.defused(reply.text))
            }
        }
        if !result.notes.isEmpty { lines += [""] + result.notes.map { "note: \($0)" } }
        return lines.joined(separator: "\n")
    }

    /// The usage report: totals against the period before, then one block per list. Counts in a right-aligned column so
    /// the eye runs down them; an element's label after its id when the registry has one.
    static func usage(_ result: UsageResult) -> String {
        let zone = TimeZone(identifier: result.period.timeZone) ?? .current
        func day(_ date: Date) -> String {
            date.formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day())
        }
        func span(_ period: UsageResult.Period) -> String {
            let lastDay = period.until.addingTimeInterval(-1)
            return day(period.since) == day(lastDay) ? day(lastDay) : "\(day(period.since)) → \(day(lastDay))"
        }
        func count(_ value: Int) -> String {
            let text = String(value)
            return String(repeating: " ", count: max(0, 6 - text.count)) + text
        }
        func change(_ now: Int, _ before: Int) -> String {
            now == before ? "=" : (now > before ? "+\(now - before)" : "−\(before - now)")
        }
        func name(_ id: String, _ label: String?) -> String {
            guard let label, label != id else { return id }
            return "\(id) — \(label)"
        }
        func duration(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            if total < 60 { return "\(total)s" }
            if total < 3600 { return "\(total / 60)m\(String(format: "%02d", total % 60))s" }
            return "\(total / 3600)h\(String(format: "%02d", total % 3600 / 60))m"
        }

        var lines = ["\(result.period.label): \(span(result.period)) (\(result.period.timeZone))",
                     "\(result.total) events (\(change(result.total, result.previousTotal)) against \(span(result.previousPeriod)))"
                        + (result.recording ? "" : " · recording is off")]
        if result.total == 0 && result.neverUsed.isEmpty {
            lines += ["", "nothing recorded in this period"]
        }
        if !result.areas.isEmpty {
            lines += ["", "by area"]
            for area in result.areas {
                lines.append("  \(count(area.count))  \(area.area) (\(change(area.count, area.previous)))")
                lines += area.top.map { "            \(count($0.count))  \(name($0.id, $0.label))" }
            }
        }
        if !result.commands.isEmpty {
            lines += ["", "commands          total  keyboard  menu  palette  mouse"]
            for command in result.commands {
                let cells = [command.total, command.keyboard, command.menu, command.palette, command.mouse].map(count)
                lines.append("  \(name(command.id, command.label))")
                lines.append("                   " + cells.joined(separator: "  "))
            }
        }
        if !result.control.isEmpty {
            lines += ["", "cli / mcp calls     user  agent"]
            lines += result.control.map { "  \($0.method.padding(toLength: 16, withPad: " ", startingAt: 0))\(count($0.user)) \(count($0.agent))" }
        }
        if !result.views.isEmpty {
            lines += ["", "time on screen"]
            lines += result.views.map { "  \(duration($0.seconds).padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.opens)× \(name($0.id, $0.label))" }
        }
        if !result.settings.isEmpty {
            lines += ["", "settings changed"]
            lines += result.settings.map { "  \(count($0.count))  \($0.id)" }
        }
        if !result.rising.isEmpty || !result.falling.isEmpty {
            lines += ["", "against the period before"]
            lines += result.rising.map { "  \(change($0.count, $0.previous).padding(toLength: 6, withPad: " ", startingAt: 0)) \(name($0.id, $0.label)) (\($0.previous) → \($0.count))" }
            lines += result.falling.map { "  \(change($0.count, $0.previous).padding(toLength: 6, withPad: " ", startingAt: 0)) \(name($0.id, $0.label)) (\($0.previous) → \($0.count))" }
        }
        if !result.neverUsed.isEmpty {
            lines += ["", "never used in this period (\(result.neverUsed.count))"]
            var area: String?
            for element in result.neverUsed {
                if element.area != area {
                    area = element.area
                    lines.append("  \(element.area)")
                }
                lines.append("    \(name(element.id, element.label))")
            }
        }
        lines += [""] + result.limits.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    /// Untrusted text between the markers, the warning first: tool descriptions get skimmed, this does not.
    static func quoted(_ text: String) -> [String] {
        [ThreadTranscript.untrustedNotice, ThreadTranscript.openMarker] + (text.isEmpty ? [] : [text])
            + [ThreadTranscript.closeMarker]
    }

    static let staleNotice = "(from before its latest prompt: that one has not been answered yet)"

    static func time(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// What a failure prints on stderr.
    public static func text(_ error: ControlError) -> String {
        var text = "scope: \(error.message)"
        if let detail = error.detail { text += "\n" + detail.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n") }
        return text
    }

    /// The BY column: Scope itself for a resident thread, the parent thread or the client otherwise.
    /// What `scope list tasks` says of a task's pull requests: `#12 open · checks failing`, or
    /// `api #12 open · checks failing · web #7 merged` when there are several; empty without one.
    static func pullRequestColumn(_ task: TaskSummary) -> String {
        let prs = task.allPullRequests
        let named = prs.count > 1
        return prs.map { $0.line(named: named) }.joined(separator: " · ")
    }

    /// What `scope list tasks` says of a task's lag on main: `behind 4`, `behind 4, 2 conflicts`, `up to date`,
    /// `held` when the user asked for no automatic rebase; empty when never measured.
    static func mainColumn(_ task: TaskSummary) -> String {
        var parts: [String] = []
        if let behind = task.behind {
            if behind == 0 { parts.append("up to date") } else { parts.append("behind \(behind)") }
            if let conflicts = task.conflicts, conflicts > 0 { parts.append("\(conflicts) conflict\(conflicts == 1 ? "" : "s")") }
        }
        if task.holdBranch == true { parts.append("held") }
        return parts.joined(separator: ", ")
    }

    /// The activity, then what the session adds when it matters: `… · compacting`, `… · MCP failed: github`.
    static func activityColumn(_ thread: ThreadSummary) -> String {
        ([thread.activity].compactMap { $0 } + (thread.session?.notes ?? [])).joined(separator: " · ")
    }

    static func openedBy(_ thread: ThreadSummary) -> String {
        if let resident = thread.resident { return "scope (\(resident))" }
        return (thread.parent.map { "thread \($0)" } ?? thread.openedBy) + (thread.depth == 0 ? "" : " (depth \(thread.depth))")
    }

    /// Space-padded columns; the last one is never padded, and an empty one leaves no padding behind it, so lines
    /// have no trailing blanks.
    static func table(_ headers: [String], _ rows: [[String]]) -> String {
        let all = [headers] + rows
        let widths = (0..<headers.count).map { column in
            all.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
        }
        return all.map { row in
            row.indices.map { column in
                let cell = row[column]
                return column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.map { String($0.reversed().drop { $0 == " " }.reversed()) }.joined(separator: "\n")
    }
}
