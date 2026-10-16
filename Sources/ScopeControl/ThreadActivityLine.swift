import Foundation
import ScopeAdapters

/// The one-line `activity` of `scope list`: the latest thing the thread's agent did, and how long ago —
/// `Edit Sources/ScopeTasks/TaskTopic.swift · 2m ago`, `finished · 1h ago`.
public enum ThreadActivityLine {
    /// `nil` when the driver has reported nothing yet. A path under `cwd` is shown relative to it.
    public static func text(_ activity: ThreadActivity, cwd: String?, now: Date) -> String? {
        var latest: (what: String, at: Date)?
        func consider(_ what: String, _ at: Date) {
            if latest.map({ at >= $0.at }) ?? true { latest = (what, at) }
        }
        // Ties go to the later candidate: a tool that opened the turn says more than "working", and an end
        // reported in the same instant as the tool before it says more than that tool.
        if let start = activity.turnStartedAt { consider("working", start) }
        if let tool = activity.lastTool {
            consider(tool.target.map { "\(tool.name) \(relative($0, to: cwd))" } ?? tool.name, tool.at)
        }
        if let turn = activity.turns.last { consider(words(turn), turn.endedAt) }
        return latest.map { "\($0.what) · \(ago($0.at, now: now))" }
    }

    static func words(_ turn: ThreadActivity.Turn) -> String {
        switch turn.outcome {
        case .ended: "finished"
        case .failed: turn.error.map { "failed (\($0))" } ?? "failed"
        case .inputRequested: "waiting for an answer"
        case .permissionRequested: "waiting for a permission"
        case .interrupted: "interrupted"
        case .exited: "stopped mid-turn"
        }
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) && path.count > base.count ? String(path.dropFirst(base.count)) : path
    }

    /// `just now`, `42s ago`, `2m ago`, `3h ago`, `5d ago`. A date in the future (clock skew) reads as now.
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        return switch seconds {
        case ..<5: "just now"
        case ..<60: "\(seconds)s ago"
        case ..<3600: "\(seconds / 60)m ago"
        case ..<86_400: "\(seconds / 3600)h ago"
        default: "\(seconds / 86_400)d ago"
        }
    }
}
