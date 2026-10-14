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
            depth ≤ \(automation.maxDepth), threads \(automation.threads.rawValue), tasks \(automation.tasks.rawValue), \
            reach \(automation.threadReach.rawValue)
            """
        case .list(let result):
            var blocks: [String] = []
            if !result.scopes.isEmpty {
                blocks.append(table(["SCOPE", "PATH", "REPOS"], result.scopes.map {
                    [$0.slug + ($0.status == "ok" ? "" : " (\($0.status))"), $0.path, "\($0.repos.count)"]
                }))
            }
            if !result.tasks.isEmpty {
                blocks.append(table(["TASK", "NAME", "SCOPE", "BRANCH", "ROOT"], result.tasks.map {
                    [$0.slug, $0.name, $0.scopeSlug, $0.branch, $0.root]
                }))
            }
            if !result.threads.isEmpty {
                blocks.append(table(["THREAD", "TITLE", "DRIVER", "STATE", "SCOPE", "TASK", "BY"], result.threads.map {
                    [$0.id, $0.title, $0.driver, $0.state, $0.scopeSlug, $0.task ?? "",
                     ($0.parent.map { "thread \($0)" } ?? $0.openedBy) + ($0.depth == 0 ? "" : " (depth \($0.depth))")]
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
            if let root = result.root { lines.append("sandbox     \(root)") }
            for repo in result.repos {
                lines.append("repo        \(repo.repo) → \(repo.worktree)\(repo.branchCreated ? " (branch created)" : "")")
            }
            if let thread = result.thread { lines.append("thread      \(thread)") }
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
                    lines += quoted(reply)
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Untrusted text between the markers, the warning first: tool descriptions get skimmed, this does not.
    static func quoted(_ text: String) -> [String] {
        [ThreadTranscript.untrustedNotice, ThreadTranscript.openMarker] + (text.isEmpty ? [] : [text])
            + [ThreadTranscript.closeMarker]
    }

    static func time(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// What a failure prints on stderr.
    public static func text(_ error: ControlError) -> String {
        var text = "scope: \(error.message)"
        if let detail = error.detail { text += "\n" + detail.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n") }
        return text
    }

    /// Space-padded columns; the last one is never padded so lines have no trailing blanks.
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
        }.joined(separator: "\n")
    }
}
