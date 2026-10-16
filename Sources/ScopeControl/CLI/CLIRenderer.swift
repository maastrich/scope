import Foundation

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
        case .usage(let result): try encoder.encode(result)
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
            reach \(automation.threadReach.rawValue)
            budget      \(automation.maxAgentTasks) open tasks, \(automation.maxAgentThreads) running threads\
            \(automation.depthLimit.map { ", depth ≤ \($0)" } ?? ", any depth")
            """
        case .list(let result):
            var blocks: [String] = []
            if !result.scopes.isEmpty {
                blocks.append(table(["SCOPE", "PATH", "REPOS"], result.scopes.map {
                    [$0.slug + ($0.status == "ok" ? "" : " (\($0.status))"), $0.path, "\($0.repos.count)"]
                }))
            }
            if !result.tasks.isEmpty {
                blocks.append(table(["TASK", "NAME", "SCOPE", "TOPIC", "BRANCH", "ROOT"], result.tasks.map {
                    [$0.slug + ($0.archivedAt == nil ? "" : " (archived)"), $0.name, $0.scopeSlug, $0.topic ?? "", $0.branch, $0.root]
                }))
            }
            if !result.threads.isEmpty {
                blocks.append(table(["THREAD", "TITLE", "DRIVER", "STATE", "SCOPE", "TASK", "TOKENS", "BY", "ACTIVITY"], result.threads.map {
                    [$0.id, $0.title, $0.driver, $0.state, $0.scopeSlug, $0.task ?? "", $0.tokens ?? "", openedBy($0), $0.activity ?? ""]
                }))
            }
            return blocks.isEmpty ? "nothing yet" : blocks.joined(separator: "\n\n")
        case .thread(let result):
            var line = "thread \(result.thread) — \(result.title) [\(result.driver)] in \(result.scopeSlug)"
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
            if let note = result.note { lines.append("note        \(note)") }
            if !result.created {
                lines.append("")
                lines.append("Nothing was written. Run it again without --dry-run to create it.")
            }
            return lines.joined(separator: "\n")
        case .action(let result, _):
            return result.message
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
                lines.append("thread \(entry.thread) — \(entry.title) (\(entry.state)\(entry.settled ? "" : ", still at work"))")
                if let reply = entry.reply {
                    lines.append("last reply" + (entry.replyAt.map { " at " + time($0) } ?? "") + ":")
                    if entry.staleReply == true { lines.append(staleNotice) }
                    lines += quoted(reply)
                }
            }
            return lines.joined(separator: "\n")
        case .summary(let result):
            return summary(result)
        case .usage(let result):
            return usage(result)
        }
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
            if let pr = task.pullRequest { parts.append("#\(pr.number)" + (pr.state.map { " \($0)" } ?? " (state unknown)")) }
            var when = "created \(day(task.createdAt))"
            if let closed = task.closedAt { when += ", closed \(day(closed))" }
            else if let archived = task.archivedAt { when += ", archived \(day(archived))" }
            else { when += ", last active \(day(task.lastActivity))" }
            parts.append(when)
            if !task.threads.isEmpty { parts.append("\(task.threads.count) thread\(task.threads.count == 1 ? "" : "s")") }
            if let tokens = task.tokens { parts.append("\(TokenUsageText.compact(tokens)) tokens all told") }
            if task.createdByAgent { parts.append("by an agent") }
            var out = [indent + task.outcome.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0) + parts.joined(separator: " · ")]
            if let brief = task.brief { out.append(indent + String(repeating: " ", count: 10) + brief) }
            return out
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
            if let pr = task.pullRequest { lines.append("pr          #\(pr.number) \(pr.title) (\(pr.state ?? "state unknown")) \(pr.url.absoluteString)") }
            lines.append("created     \(day(task.createdAt))" + (task.createdByAgent ? " by an agent" : ""))
            if let tokens = task.tokens { lines.append("tokens      \(TokenUsageText.compact(tokens))") }
            if let archived = task.archivedAt { lines.append("archived    \(day(archived))") }
            if let closed = task.closedAt { lines.append("closed      \(day(closed))") }
            for thread in task.threads { lines.append("thread      " + threadLine(thread)) }
            if let prompt = detail.prompt { lines += ["", "brief:", prompt] }
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
