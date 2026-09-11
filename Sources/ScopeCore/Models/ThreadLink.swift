import Darwin
import Foundation

/// A link that brings Scope up on one thread: `scope://thread?session=<driver session id>&pid=<pid>`, or
/// `scope://thread?id=<thread id>`. A Debug build answers to `scope-debug://` instead, so a link never lands in
/// the other copy of the app.
///
/// It exists for tools that know a driver session but nothing about Scope. Vibe Island's custom jump rules
/// (`~/.vibe-island/integrations.json`) expand `{session_id}` and `{pid}` into a URL template and open it
/// when a session card is clicked; without this, clicking brought the window up on whatever thread was selected.
public struct ThreadLink: Equatable, Sendable {
    /// The URL schemes the app registers (`CFBundleURLTypes`): Release, then Debug.
    public static let schemes: Set<String> = ["scope", "scope-debug"]
    /// The URL host every thread link uses.
    public static let host = "thread"

    /// `id=`: a Scope thread id.
    public var threadID: ThreadID?
    /// `session=`: the driver's own session id, what `ThreadRecord.resumeID` holds (Claude Code's `session_id`).
    public var sessionID: String?
    /// `pid=`: the driver process, or any process below the thread's PTY child.
    public var pid: pid_t?

    public init(threadID: ThreadID? = nil, sessionID: String? = nil, pid: pid_t? = nil) {
        self.threadID = threadID
        self.sessionID = sessionID
        self.pid = pid
    }

    /// `nil` unless `url` is `<scope scheme>://thread?…` carrying at least one usable parameter.
    ///
    /// Values that are empty or still hold a `{placeholder}` are ignored: a jump rule expands a placeholder it
    /// cannot fill to nothing, or leaves it as written, and neither names a thread.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == Self.host
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty, !value.contains("{")
            else { continue }
            values[item.name] = value
        }
        threadID = values["id"].flatMap(ThreadID.init(rawValue:))
        sessionID = values["session"]
        pid = values["pid"].flatMap { pid_t($0) }.flatMap { $0 > 1 ? $0 : nil }
        guard threadID != nil || sessionID != nil || pid != nil else { return nil }
    }

    /// One thread as the resolver sees it.
    public struct Candidate: Equatable, Sendable {
        public var id: ThreadID
        /// `ThreadRecord.resumeID`.
        public var sessionID: String?
        /// The PTY child's pid while the thread runs.
        public var pid: pid_t?

        public init(id: ThreadID, sessionID: String?, pid: pid_t?) {
            self.id = id
            self.sessionID = sessionID
            self.pid = pid
        }
    }

    /// How far up the process tree `resolve` climbs from `pid` before giving up.
    static let maxAncestry = 32

    /// The thread the link means: the one it names, else the one running its driver session, else the one whose
    /// PTY child is `pid` or an ancestor of it.
    ///
    /// The session wins over the pid because it survives a relaunch, while a pid can be reused by an unrelated
    /// process. When two records carry the same session (a thread resumed into another), the running one wins.
    /// The pid is climbed rather than compared because the driver may sit under a login shell the PTY started.
    public func resolve(_ candidates: [Candidate], parent: (pid_t) -> pid_t? = ThreadLink.parentPID(of:)) -> ThreadID? {
        if let threadID, candidates.contains(where: { $0.id == threadID }) {
            return threadID
        }
        if let sessionID {
            let matches = candidates.filter { $0.sessionID == sessionID }
            if let match = matches.first(where: { $0.pid != nil }) ?? matches.first {
                return match.id
            }
        }
        if let pid {
            let byPID = Dictionary(candidates.compactMap { candidate in candidate.pid.map { ($0, candidate.id) } },
                                   uniquingKeysWith: { first, _ in first })
            var current: pid_t? = pid
            for _ in 0..<Self.maxAncestry {
                guard let process = current, process > 1 else { break }
                if let id = byPID[process] { return id }
                current = parent(process)
            }
        }
        return nil
    }

    /// The parent of `pid` from the kernel's process table; `nil` when the process is gone.
    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
