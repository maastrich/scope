import Darwin
import Foundation

/// Finds and stops the processes that belong to a folder Scope is about to remove: anything of the current user
/// whose working directory lies under it, or whose environment names it as `SCOPE_TASK_ROOT` (a process that
/// `cd`'d elsewhere still carries the variable its thread was started with).
///
/// Hanging up a thread only reaches its shell and the foreground job; dev servers, watchers and anything an agent
/// started in the background outlive it. This is what makes sure none of them survives its task.
public enum ProcessSweep {
    public struct Match: Sendable, Equatable, CustomStringConvertible {
        public var pid: pid_t
        public var name: String
        public var directory: String?
        /// `SCOPE_TASK_ROOT` from its environment, when it has one.
        public var taskRoot: String?

        public var description: String { "\(name) (\(pid))" }
    }

    public struct Result: Sendable, Equatable {
        /// Processes that were signalled and are gone.
        public var stopped: [Match] = []
        /// Processes still alive after SIGKILL — not ours to kill, or stuck in the kernel.
        public var survivors: [Match] = []
    }

    /// The live processes of this user under any of `roots` — by working directory, or by a `SCOPE_TASK_ROOT`
    /// that is one of them or lies inside one — never the current process.
    public static func processes(under roots: [URL]) -> [Match] {
        let prefixes = roots.flatMap(Self.spellings)
        guard !prefixes.isEmpty else { return [] }
        let me = getpid()
        let uid = getuid()
        return allPids().compactMap { pid in
            guard pid > 0, pid != me, let info = bsdInfo(pid), info.pbi_uid == uid, info.pbi_status != SZOMB else {
                return nil
            }
            let cwd = currentDirectory(pid)
            let taskRoot = environment(pid)["SCOPE_TASK_ROOT"].map(Self.trimmed)
            guard [cwd, taskRoot].contains(where: { path in path.map { isInside($0, prefixes) } ?? false }) else { return nil }
            return Match(pid: pid, name: Self.name(info), directory: cwd, taskRoot: taskRoot)
        }
    }

    /// `path` is one of `prefixes` or lies under one.
    public static func isInside(_ path: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// SIGTERM to every process under `roots`, SIGKILL to whatever is left after `grace`, then one more look.
    public static func stop(under roots: [URL], grace: Duration = .seconds(3)) async -> Result {
        await stop(processes(under: roots), grace: grace)
    }

    /// SIGTERM to `found`, SIGKILL to whatever is left after `grace`, then one more look.
    public static func stop(_ found: [Match], grace: Duration = .seconds(3)) async -> Result {
        guard !found.isEmpty else { return Result() }
        for match in found { kill(match.pid, SIGTERM) }
        var alive = await waitForExit(found, within: grace)
        for match in alive { kill(match.pid, SIGKILL) }
        alive = await waitForExit(alive, within: .seconds(1))
        let survivors = Set(alive.map(\.pid))
        return Result(stopped: found.filter { !survivors.contains($0.pid) }, survivors: alive)
    }

    // MARK: - Internals

    private static func waitForExit(_ matches: [Match], within limit: Duration) async -> [Match] {
        let deadline = ContinuousClock.now + limit
        var alive = matches.filter(isAlive)
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            alive = alive.filter(isAlive)
        }
        return alive
    }

    /// A zombie counts as gone: it holds nothing, it only waits for its parent to read its status.
    private static func isAlive(_ match: Match) -> Bool {
        guard kill(match.pid, 0) == 0 || errno == EPERM else { return false }
        return bsdInfo(match.pid).map { $0.pbi_status != SZOMB } ?? false
    }

    /// The path as given and as the kernel reports it (`/var` → `/private/var`), without a trailing slash.
    public static func spellings(_ url: URL) -> [String] {
        let plain = trimmed(url.path)
        var resolved = plain
        if let real = realpath(plain, nil) {
            resolved = String(cString: real)
            free(real)
        } else if let parent = realpath((plain as NSString).deletingLastPathComponent, nil) {
            // The folder is gone already; its parent still says where the kernel put it.
            resolved = trimmed(String(cString: parent)) + "/" + (plain as NSString).lastPathComponent
            free(parent)
        }
        // Never "/" or a home: a root that short would match half the machine.
        return Set([plain, trimmed(resolved)]).filter { $0.split(separator: "/").count >= 3 }.sorted()
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func name(_ info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_name) { bytes in
            let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            return name.isEmpty ? withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : name
        }
    }

    private static func currentDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// `KERN_PROCARGS2`: argc, the executable path, then argv and the environment as NUL-separated strings.
    /// Readable for the current user's own processes only, which are the only ones swept. The kernel keeps the
    /// environment of Apple's platform binaries to itself; their `argv` is still given.
    public static func environment(_ pid: pid_t) -> [String: String] {
        guard let (argc, strings) = processArguments(pid) else { return [:] }
        // strings[0] is the executable path, then argc arguments, then the environment.
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(1 + argc) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment
    }

    /// `argv` of a process of the current user — `["python3", "-m", "http.server", "4310"]` — or empty when the
    /// kernel gives nothing (gone, another user's).
    public static func arguments(_ pid: pid_t) -> [String] {
        guard let (argc, strings) = processArguments(pid), argc > 0 else { return [] }
        return Array(strings.dropFirst().prefix(argc))
    }

    /// The parent of a process, `nil` for a pid the kernel no longer knows.
    public static func parent(of pid: pid_t) -> pid_t? {
        bsdInfo(pid).map { pid_t($0.pbi_ppid) }
    }

    private static func processArguments(_ pid: pid_t) -> (argc: Int, strings: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size]
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return (Int(max(argc, 0)), strings)
    }
}
