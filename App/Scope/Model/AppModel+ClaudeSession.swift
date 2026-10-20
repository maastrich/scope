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
    }
}
