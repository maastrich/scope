import Darwin
import Foundation
import ScopeAdapters
import ScopeControl
import ScopeCore

/// A Claude Code thread's background work (`ClaudeBackgroundWork`): what the Background card and the answers to
/// agents show, and stopping one task from the card.
///
/// Stopping signals the task's own process group, found among the thread's descendants (`BackgroundProcess`). Of the
/// three ways there are, it is the one that hits exactly the task asked for and nothing else:
/// - Claude Code's `/tasks` dialog stops a task too, but only by keystrokes in a list whose order and selection Scope
///   cannot read back — a wrong row is somebody else's dev server;
/// - asking the agent to `TaskStop` it costs a turn, waits for the agent to be idle, and leaves it to the agent;
/// - the process is unambiguous: a shell task writes to `tasks/<id>.output`, a Monitor evals exactly its command.
/// Claude Code then reports the task `failed (exit 144)` like any command that died, and the agent learns of it from
/// that notification — it may decide to start it again. A wake-up or a cron has no process: the card offers no stop.
extension AppModel {
    enum BackgroundStopOutcome: Equatable {
        case stopped
        case notFound
        case survived
    }

    /// Stops background task `id` of `session`, after the user confirmed it.
    @discardableResult
    func stopBackgroundTask(_ id: String, of session: ThreadSession) async -> BackgroundStopOutcome {
        guard let pid = session.pid, let task = session.claude.background.task(id), task.status(at: .now).isRunning else {
            return .notFound
        }
        Usage.click("inspector.background.stop", label: "Stop a background task")
        let outputFile = ClaudeBackgroundWork.outputFile(of: task, transcriptPath: session.activity.transcriptPath)
        let command = task.command
        let target = await Task.detached(priority: .userInitiated) {
            BackgroundProcess.find(under: pid, outputFile: outputFile, command: command)
        }.value
        guard let target else {
            problems.warn("Cannot stop \(id)",
                          detail: "Scope found no single process for it under the thread. Ask the agent to stop it (TaskStop \(id)).")
            return .notFound
        }
        Log.threads.notice("thread \(session.id.rawValue, privacy: .public) stopping background task \(id, privacy: .public) (pid \(target.pid))")
        session.markBackgroundStopRequested(id)
        let gone = await BackgroundProcess.stop(target)
        // The notification that follows is in the transcript: read it now rather than at the next tick.
        readClaudeTranscriptSoon(session)
        if !gone {
            problems.warn("\(id) is still running", detail: "Its process \(target.pid) did not exit after SIGTERM and SIGKILL.")
        }
        return gone ? .stopped : .survived
    }

    /// The end of a background task's output, read off the main thread.
    nonisolated static func readBackgroundOutput(_ path: String) async -> FileTail.Result {
        await Task.detached(priority: .utility) { FileTail.read(path) }.value
    }
}

extension ThreadSession {
    /// `BackgroundWorkReport.entries` of this thread, each task's output file resolved.
    func backgroundReport(now: Date = .now) -> [BackgroundTaskSummary]? {
        let transcript = activity.transcriptPath
        return BackgroundWorkReport.entries(claude.background, now: now) {
            ClaudeBackgroundWork.outputFile(of: $0, transcriptPath: transcript)
        }
    }

    /// Whether a running task of this thread can be stopped from Scope: a shell or a Monitor, its process alive.
    func canStopBackgroundTask(_ task: ClaudeBackgroundWork.Task, now: Date = .now) -> Bool {
        isAlive && task.status(at: now).isRunning
    }
}
