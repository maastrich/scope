import Foundation
import ScopeAdapters
import ScopeCore

/// Following each Claude Code thread's transcript for what no hook says (`ClaudeTranscriptTail`): a background command
/// or sub-agent finishing, compactions, the permission mode, MCP servers. Read off the main thread, from where the last
/// read stopped, right after each hook event and every few seconds besides — a background command can finish while
/// the session sends no hook at all.
extension AppModel {
    /// How often every live thread's transcript is looked at without a hook to prompt it. A look at an unchanged file
    /// is one `stat`-like seek.
    static let claudeTranscriptInterval: Duration = .seconds(3)
    /// The pause after a hook event before reading: the transcript line is often written just after the hook runs.
    static let claudeTranscriptSettle: Duration = .milliseconds(300)

    /// The pause before asking `gh` about a pull request a thread just reported: `gh pr create` and a `pr-link`
    /// arrive within moments of each other, and one look covers both.
    static let claudePullRequestSettle: Duration = .seconds(2)

    func wireClaudeSession(_ session: ThreadSession) {
        session.onClaudeSessionStarted = { [weak self] session, cwd in
            self?.readMCPConfiguration(for: session, cwd: cwd)
        }
        session.onClaudePullRequests = { [weak self] session, entries in
            self?.claudeReportedPullRequests(entries, from: session)
        }
    }

    /// Reads which MCP servers the configuration declares for `cwd` — `~/.claude.json` is large, so off the main
    /// thread, and only at a session start, never on the transcript's tick.
    func readMCPConfiguration(for session: ThreadSession, cwd: String) {
        Task { [weak session] in
            let declarations = await Task.detached(priority: .utility) {
                ClaudeMCPConfig.read(claudeJSON: ClaudeMCPConfig.defaultClaudeJSON(), cwd: cwd)
            }.value
            session?.declareMCPServers(declarations)
        }
    }

    /// A thread opened or merged a pull request: its task's pull requests are asked about now rather than at the
    /// next background pass, minutes away. One reported before this launch is not news.
    func claudeReportedPullRequests(_ entries: [ClaudeSessionPullRequests.Entry], from session: ThreadSession) {
        guard let task = task(of: session), !task.isArchived,
              entries.contains(where: { ($0.at ?? .distantPast) >= claudeSessionWatchStart }) else { return }
        let id = task.id
        claudePullRequestRefreshes[id]?.cancel()
        claudePullRequestRefreshes[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.claudePullRequestSettle)
            guard !Task.isCancelled, let self, let task = self.task(id), !task.isArchived else { return }
            self.claudePullRequestRefreshes[id] = nil
            await self.refreshTaskPullRequest(task)
            await self.archiveIfMerged(task)
        }
    }

    func startClaudeTranscriptReader() {
        guard claudeTranscriptReader == nil else { return }
        claudeTranscriptReader = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.claudeTranscriptInterval)
                guard let self else { return }
                for session in threads where session.isAlive {
                    await readClaudeTranscript(session)
                }
            }
        }
    }

    /// Reads `session`'s transcript shortly, unless a read is already under way.
    func readClaudeTranscriptSoon(_ session: ThreadSession) {
        guard !session.transcriptTailReading, session.activity.transcriptPath != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.claudeTranscriptSettle)
            await self?.readClaudeTranscript(session)
        }
    }

    /// Reads what `session`'s transcript gained and folds it into `session.claude`.
    func readClaudeTranscript(_ session: ThreadSession) async {
        guard !session.transcriptTailReading, let path = session.activity.transcriptPath, !path.isEmpty else { return }
        session.transcriptTailReading = true
        defer { session.transcriptTailReading = false }
        let start = session.transcriptTail
        let (records, tail) = await Task.detached(priority: .utility) {
            var tail = start
            let records = (try? tail.read(URL(fileURLWithPath: path))) ?? []
            return (records, tail)
        }.value
        session.transcriptTail = tail
        session.applyTranscript(records)
        await readSubagentMeta(session, sessionTranscript: path)
    }

    /// Looks a missing `meta.json` up this many times before giving up on it: written when the sub-agent spawns, so
    /// one still absent after a few reads never will be.
    static let subagentMetaAttempts = 5

    /// Reads the `meta.json` of each sub-agent that has none yet, beside the session's transcript.
    func readSubagentMeta(_ session: ThreadSession, sessionTranscript: String) async {
        let ids = session.claude.subagents.agentsWithoutMeta.filter {
            (session.subagentMetaMisses[$0] ?? 0) < Self.subagentMetaAttempts
        }
        guard !ids.isEmpty else { return }
        let found = await Task.detached(priority: .utility) {
            ids.map { id -> (String, ClaudeSubagentMeta?, String) in
                let meta = ClaudeSubagentMeta.read(ClaudeSubagents.metaURL(agentID: id, sessionTranscript: sessionTranscript))
                return (id, meta, ClaudeSubagents.transcriptURL(agentID: id, sessionTranscript: sessionTranscript).path)
            }
        }.value
        for (id, meta, _) in found where meta == nil { session.subagentMetaMisses[id, default: 0] += 1 }
        session.applySubagentMeta(found.compactMap { id, meta, transcript in meta.map { (id, $0, transcript) } })
    }
}
