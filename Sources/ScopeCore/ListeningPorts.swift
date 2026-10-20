import Darwin
import Foundation

/// The TCP ports a set of processes listen on, read from the kernel the way `lsof -iTCP -sTCP:LISTEN` reads them
/// (`proc_pidfdinfo` on each socket descriptor), for the current user's own processes.
///
/// Every task gets a block of ports (`PortBlock`); the ones a dev server actually took are what the task's section
/// shows as `localhost:41003 ↗`. The walk over descriptors is a few hundred syscalls per process: cheap enough to run
/// every twenty seconds for the tasks whose threads are alive, and nothing else is scanned.
public enum ListeningPorts {
    public struct Listener: Sendable, Equatable, Hashable, Comparable {
        public var port: Int
        public var pid: pid_t

        public init(port: Int, pid: pid_t) {
            self.port = port
            self.pid = pid
        }

        public static func < (lhs: Listener, rhs: Listener) -> Bool { (lhs.port, lhs.pid) < (rhs.port, rhs.pid) }
    }

    /// Every TCP listener of `pids`, lowest port first, one entry per (port, pid).
    public static func listeners(of pids: [pid_t]) -> [Listener] {
        var found = Set<Listener>()
        for pid in pids {
            for port in listeningPorts(of: pid) { found.insert(Listener(port: port, pid: pid)) }
        }
        return found.sorted()
    }

    /// The listening TCP ports of one process, in no order.
    static func listeningPorts(of pid: pid_t) -> Set<Int> {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count + 16)
        let read = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard read > 0 else { return [] }
        var ports = Set<Int>()
        for descriptor in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let wanted = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, wanted) == wanted else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP, [AF_INET, AF_INET6].contains(Int32(info.psi.soi_family)) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            if let port = port(fromNetworkOrder: tcp.tcpsi_ini.insi_lport) { ports.insert(port) }
        }
        return ports
    }

    /// `insi_lport` holds the port in network byte order in its low 16 bits.
    static func port(fromNetworkOrder raw: Int32) -> Int? {
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
        return port > 0 ? port : nil
    }
}

/// The block of ports a task owns: `SCOPE_PORT` and the nine after it.
public struct PortBlock: Sendable, Equatable, Hashable {
    public var base: Int
    public var size: Int

    public init(base: Int, size: Int = 10) {
        self.base = base
        self.size = size
    }

    public var range: Range<Int> { base..<(base + size) }

    public func contains(_ port: Int) -> Bool { range.contains(port) }

    /// The ports of `listeners` inside the block, ascending, each once however many processes share it.
    public func ports(in listeners: [ListeningPorts.Listener]) -> [Int] {
        Array(Set(listeners.map(\.port).filter(contains))).sorted()
    }

    /// `http://localhost:<port>`: what a click on a port chip opens.
    public static func url(for port: Int) -> URL {
        URL(string: "http://localhost:\(port)")!
    }
}

extension PortBlock {
    /// Ports the task's processes listen on outside the block — Vite's 5173, Next's 3000 when nobody passed
    /// `--port $SCOPE_PORT` — ascending. The ephemeral range is left out: a debugger or a language server binds
    /// there, not a dev server.
    public func otherServerPorts(in listeners: [ListeningPorts.Listener]) -> [Int] {
        Array(Set(listeners.map(\.port).filter { !contains($0) && (1024..<49152).contains($0) })).sorted()
    }
}

/// `.claude/launch.json`, the file Claude Code's desktop app reads to start a project's dev servers: each
/// configuration may say the `port` it serves, or a `url`. Read only for the ports, so the task's browser knows where
/// to look before anything listens.
public enum LaunchConfig {
    public struct Server: Equatable, Sendable {
        public var name: String?
        public var port: Int?
        public var url: URL?

        public init(name: String? = nil, port: Int? = nil, url: URL? = nil) {
            self.name = name
            self.port = port
            self.url = url
        }

        /// Where the browser goes for it: the url as written, else `http://localhost:<port>`.
        public var address: URL? { url ?? port.map(PortBlock.url(for:)) }
    }

    /// The servers a launch.json declares; nothing for a file that does not parse. Comments (`//`) are allowed, as in
    /// VS Code's own launch.json.
    public static func servers(_ data: Data) -> [Server] {
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                return trimmed.hasPrefix("//") ? "" : line
            }
            .joined(separator: "\n")
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let configurations = object["configurations"] as? [[String: Any]] else { return [] }
        return configurations.compactMap { entry in
            let port = (entry["port"] as? Int) ?? (entry["port"] as? String).flatMap(Int.init)
            let url = (entry["url"] as? String).flatMap(URL.init(string:))
            guard port != nil || url != nil else { return nil }
            return Server(name: entry["name"] as? String, port: port, url: url)
        }
    }
}
