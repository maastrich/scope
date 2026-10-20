import Darwin
import Foundation

/// The processes behind a task's listening ports, as the Environment card lists them under the port chips: one line
/// per process, its command line, the thread it was started from when that can be told.
///
/// `ListeningPorts` already says *which* ports of the block are taken, from the sockets of the processes under the
/// task's root. This answers *who* holds them, through `lsof -nP -iTCP:<port> -sTCP:LISTEN -F pcn` run on demand —
/// `lsof` sees listeners whatever their working directory, which the sweep's lookup does not — and the kernel's own
/// `argv` for the command line. Everything here is a pure function over text and closures, so it can be tested with
/// fixtures; the app runs `lsof` through `Subprocess` off the main actor.
public enum ListeningProcesses {
    /// One `(pid, port)` pair of `lsof`'s output; `command` is the short name `lsof` prints (`python3.12`).
    public struct Entry: Sendable, Equatable, Hashable, Comparable {
        public var pid: pid_t
        public var command: String
        public var port: Int

        public init(pid: pid_t, command: String, port: Int) {
            self.pid = pid
            self.command = command
            self.port = port
        }

        public static func < (lhs: Entry, rhs: Entry) -> Bool { (lhs.port, lhs.pid) < (rhs.port, rhs.pid) }
    }

    /// One process of the list: every port of the block it listens on, its command line, and the Scope thread it
    /// belongs to (`SCOPE_THREAD` in its environment, or a thread's shell among its ancestors) when known.
    public struct Process: Sendable, Equatable, Hashable, Identifiable {
        public var pid: pid_t
        public var ports: [Int]
        /// `argv` joined by spaces, or `lsof`'s short name when the kernel gives nothing.
        public var commandLine: String
        /// The id of the thread the process was started from, when one could be told.
        public var threadID: String?

        public var id: pid_t { pid }

        public init(pid: pid_t, ports: [Int], commandLine: String, threadID: String? = nil) {
            self.pid = pid
            self.ports = ports
            self.commandLine = commandLine
            self.threadID = threadID
        }
    }

    /// The arguments of the one `lsof` call that lists every listener of `ports`: several `-i` select the union.
    /// Field output (`-F pcn`) is what `parse` reads — `p<pid>`, `c<command>`, then one `n<address>` per socket.
    public static func lsofArguments(ports: [Int]) -> [String] {
        ["-nP"] + ports.sorted().map { "-iTCP:\($0)" } + ["-sTCP:LISTEN", "-F", "pcn"]
    }

    /// `lsof -F pcn` output into entries, lowest port first, one per `(port, pid)` however many sockets a process
    /// has on the port (IPv4 and IPv6 at once is the usual pair). Lines that are none of `p`, `c`, `n` are skipped,
    /// and a network name whose port cannot be read (`*:*`, a UNIX socket) is skipped too.
    public static func parse(_ output: String) -> [Entry] {
        var found = Set<Entry>()
        var pid: pid_t?
        var command = ""
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = pid_t(value)
                command = ""
            case "c":
                command = value
            case "n":
                guard let pid, let port = port(in: value) else { continue }
                found.insert(Entry(pid: pid, command: command, port: port))
            default:
                continue
            }
        }
        return found.sorted()
    }

    /// The port of an `lsof` network name: `*:4310`, `127.0.0.1:4310`, `[::1]:4310`, or `host:4310->peer:1234`
    /// (only the local side counts).
    static func port(in name: String) -> Int? {
        let local = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        guard let colon = local.lastIndex(of: ":") else { return nil }
        let digits = local[local.index(after: colon)...]
        guard let port = Int(digits), port > 0 else { return nil }
        return port
    }

    /// Entries folded into one line per process, in the order of their lowest port. `commandLine` and `owner` are
    /// asked once per pid; a `nil` command line falls back to `lsof`'s short name.
    public static func processes(
        _ entries: [Entry], commandLine: (pid_t) -> String?, owner: (pid_t) -> String?
    ) -> [Process] {
        var order: [pid_t] = []
        var ports: [pid_t: Set<Int>] = [:]
        var names: [pid_t: String] = [:]
        for entry in entries.sorted() {
            if ports[entry.pid] == nil {
                order.append(entry.pid)
                names[entry.pid] = entry.command
            }
            ports[entry.pid, default: []].insert(entry.port)
        }
        return order.map { pid in
            let line = commandLine(pid)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Process(pid: pid, ports: (ports[pid] ?? []).sorted(),
                           commandLine: line.isEmpty ? (names[pid] ?? "pid \(pid)") : line, threadID: owner(pid))
        }
    }

    /// Which Scope thread a process belongs to: the `SCOPE_THREAD` of its environment when the kernel shows it, else
    /// the first ancestor (itself included) that is a thread's shell. `threads` maps a thread's shell pid to its id.
    /// The kernel hides the environment of Apple's platform binaries (`/usr/bin/python3`), which is what the
    /// ancestry is for; the walk stops at pid 1 or after `limit` hops, a parent chain never being that deep.
    public static func owner(
        of pid: pid_t, threads: [pid_t: String], environment: (pid_t) -> [String: String], parent: (pid_t) -> pid_t?,
        limit: Int = 32
    ) -> String? {
        if let thread = environment(pid)["SCOPE_THREAD"], !thread.isEmpty { return thread }
        var current: pid_t? = pid
        var hops = 0
        var seen = Set<pid_t>()
        while let candidate = current, candidate > 1, hops < limit, seen.insert(candidate).inserted {
            if let thread = threads[candidate] { return thread }
            current = parent(candidate)
            hops += 1
        }
        return nil
    }
}
