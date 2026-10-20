import Darwin
import Foundation

/// Finds and stops the process behind one of a coding agent's background tasks, among the descendants of the
/// thread's own process — never anywhere else on the machine.
///
/// Claude Code runs each background command in a shell of its own, a direct child of its process and the leader of
/// its own process group: `zsh -c '… eval '<command>' …'`, its stdout and stderr redirected to the task's output file
/// (`…/tasks/<id>.output`) for a `Bash` task, piped back to Claude Code for a `Monitor`. Signalling that group ends the
/// command and everything it started, and Claude Code then reports the task the way it reports any command that died:
/// `failed (exit 144)`.
///
/// Found by what can only be that task: the descendant whose stdout or stderr is the output file, or else the one
/// whose command line evals exactly the task's command. Nothing is found — and nothing signalled — when no process or
/// more than one matches.
public enum BackgroundProcess {
    public struct Target: Sendable, Equatable {
        /// The topmost process of the task: the shell Claude Code started.
        public var pid: pid_t
        /// Its process group, when it leads one of its own that is neither Scope's nor the thread's.
        public var group: pid_t?
        /// It and everything below it, as found.
        public var tree: [pid_t]
    }

    /// The task's process under `root`: by `outputFile` first, then by `command`. `nil` when nothing, or more than one
    /// candidate, matches.
    public static func find(under root: pid_t, outputFile: String?, command: String?) -> Target? {
        guard root > 1 else { return nil }
        let table = processTable()
        let below = descendants(of: root, in: table)
        guard !below.isEmpty else { return nil }
        var candidates: Set<pid_t> = []
        if let outputFile, !outputFile.isEmpty {
            let spellings = Set(ProcessSweep.spellings(URL(fileURLWithPath: outputFile)))
            candidates = Set(below.filter { pid in writtenFiles(pid).contains { spellings.contains($0) } })
        }
        if candidates.isEmpty, let command, !command.isEmpty {
            candidates = Set(below.filter { evals(arguments(pid: $0), command: command) })
        }
        // The shell and the command it runs both match: the task is the topmost of them.
        let tops = candidates.filter { pid in table[pid].map { !candidates.contains($0.parent) } ?? false }
        guard tops.count == 1, let top = tops.first else { return nil }
        let tree = [top] + descendants(of: top, in: table)
        let group = table[top]?.group
        let ownGroup = group == top && group != getpgrp() && group != table[root]?.group
        return Target(pid: top, group: ownGroup ? group : nil, tree: tree)
    }

    /// SIGTERM to the task's group (or its tree, without a group of its own), SIGKILL to what is left after `grace`.
    /// `true` once nothing of it runs.
    @discardableResult
    public static func stop(_ target: Target, grace: Duration = .seconds(3)) async -> Bool {
        signal(target, SIGTERM)
        if await waitForExit(target.tree, within: grace) { return true }
        signal(target, SIGKILL)
        return await waitForExit(target.tree, within: .seconds(1))
    }

    /// `arguments` run `eval '<command>'` — the way Claude Code's shell wraps a background command, the command
    /// single-quoted with each `'` written `'\''`.
    public static func evals(_ arguments: [String], command: String) -> Bool {
        let quoted = "eval '" + command.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return arguments.contains { $0.contains(quoted) }
    }

    // MARK: - Internals

    struct Entry {
        var parent: pid_t
        var group: pid_t
    }

    private static func signal(_ target: Target, _ signal: Int32) {
        if let group = target.group { killpg(group, signal) }
        for pid in target.tree { kill(pid, signal) }
    }

    private static func waitForExit(_ pids: [pid_t], within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        var alive = pids.filter(isAlive)
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            alive = alive.filter(isAlive)
        }
        return alive.isEmpty
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        return ProcessSweep.bsdInfo(pid).map { $0.pbi_status != SZOMB } ?? false
    }

    /// Parent and group of each live process of this user.
    static func processTable() -> [pid_t: Entry] {
        let uid = getuid()
        var table: [pid_t: Entry] = [:]
        for pid in ProcessSweep.allPids() where pid > 0 {
            guard let info = ProcessSweep.bsdInfo(pid), info.pbi_uid == uid, info.pbi_status != SZOMB else { continue }
            table[pid] = Entry(parent: pid_t(info.pbi_ppid), group: pid_t(info.pbi_pgid))
        }
        return table
    }

    /// Every process below `root`, breadth first.
    static func descendants(of root: pid_t, in table: [pid_t: Entry]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, entry) in table where pid != entry.parent { children[entry.parent, default: []].append(pid) }
        var found: [pid_t] = []
        var queue = children[root] ?? []
        var seen: Set<pid_t> = [root]
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            found.append(pid)
            queue += children[pid] ?? []
        }
        return found
    }

    /// The files a process's stdout and stderr point at.
    static func writtenFiles(_ pid: pid_t) -> [String] {
        [Int32(1), 2].compactMap { fd in
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return path.isEmpty ? nil : path
        }
    }

    /// `argv`, from `KERN_PROCARGS2` (argc, the executable path, then the arguments).
    static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = Int(max(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }, 0))
        let strings = buffer[MemoryLayout<Int32>.size..<size]
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return Array(strings.dropFirst().prefix(argc))
    }
}
