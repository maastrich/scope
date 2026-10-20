import Foundation

/// What the inspector's Connectors card makes of a task's MCP servers: the lists of its live Claude Code threads
/// (`ClaudeMCPServers`), grouped, ordered trouble first, and summed up in one line for the closed header.
///
/// Threads of one task usually start in the same folder and read the same configuration, so they report the same
/// servers: the card then shows one list. When they disagree — one server failed in one thread only, a `.mcp.json`
/// in one sandbox — one group per thread, under its title, rather than a merged list that would hide which thread
/// cannot reach what.
public enum ConnectorsSummary {
    /// One thread's servers, as the card receives them.
    public struct Thread<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        public var title: String
        public var servers: [ClaudeMCPServers.Server]

        public init(id: ID, title: String, servers: [ClaudeMCPServers.Server]) {
            self.id = id
            self.title = title
            self.servers = servers
        }
    }

    /// One list of the card: every thread's when they agree (`thread` is `nil`), else one thread's.
    public struct Group<ID: Hashable & Sendable>: Sendable {
        public var thread: ID?
        public var title: String?
        public var servers: [ClaudeMCPServers.Server]
    }

    /// The dot a row draws. Claude Code never says a server is connected, so `connected` is only claimed on
    /// evidence — its tools were listed or one was called; a server merely absent from the trouble lists
    /// (`notReported`) or not reported on at all (`.unknown`) reads as `notReported`, grey.
    public enum Light: Sendable, Equatable {
        case needsAuth, failed, pending, connected, notReported
    }

    public static func light(_ server: ClaudeMCPServers.Server) -> Light {
        switch server.status {
        case .needsAuth: .needsAuth
        case .failed: .failed
        case .pending: .pending
        case .connected: server.evidence == .notReported ? .notReported : .connected
        case .unknown: .notReported
        }
    }

    /// The groups the card draws, each ordered. Threads that know no server yet are left out: a thread still
    /// starting does not disagree with one that has its list.
    public static func groups<ID>(_ threads: [Thread<ID>]) -> [Group<ID>] {
        let known = threads.filter { !$0.servers.isEmpty }
        guard let first = known.first else { return [] }
        let agree = known.dropFirst().allSatisfy { signature($0.servers) == signature(first.servers) }
        if agree {
            return [Group(thread: nil, title: nil, servers: merged(known.map(\.servers)))]
        }
        return known.map { Group(thread: $0.id, title: $0.title, servers: ordered($0.servers)) }
    }

    /// Several threads' lists as one, by name: calls add up (each thread made its own), the tool count and the
    /// error are the first thread's that has one, the status the one that is most trouble.
    public static func merged(_ lists: [[ClaudeMCPServers.Server]]) -> [ClaudeMCPServers.Server] {
        var byName: [String: ClaudeMCPServers.Server] = [:]
        var order: [String] = []
        for server in lists.joined() {
            guard var kept = byName[server.name] else {
                byName[server.name] = server
                order.append(server.name)
                continue
            }
            kept.toolCalls += server.toolCalls
            kept.tools = max(kept.tools, server.tools)
            kept.source = kept.source ?? server.source
            kept.transport = kept.transport ?? server.transport
            if rank(server) < rank(kept) {
                kept.status = server.status
                kept.isInferred = server.isInferred
                kept.evidence = server.evidence
                kept.error = server.error
                kept.errorCode = server.errorCode
            }
            byName[server.name] = kept
        }
        return ordered(order.compactMap { byName[$0] })
    }

    /// Trouble first — needing authentication, failed, still connecting — then the connected ones, then those
    /// nothing was reported about; by name inside each.
    public static func ordered(_ servers: [ClaudeMCPServers.Server]) -> [ClaudeMCPServers.Server] {
        servers.sorted { lhs, rhs in
            let (left, right) = (rank(lhs), rank(rhs))
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func rank(_ server: ClaudeMCPServers.Server) -> Int {
        switch light(server) {
        case .needsAuth: 0
        case .failed: 1
        case .pending: 2
        case .connected: 3
        case .notReported: 4
        }
    }

    /// What decides whether two threads agree: the same servers in the same state. Tool counts and calls move
    /// with each thread's own work and do not count.
    private static func signature(_ servers: [ClaudeMCPServers.Server]) -> Set<String> {
        Set(servers.map { "\($0.name)\u{1F}\(light($0))\u{1F}\($0.errorCode ?? "")" })
    }

    /// The closed header: how many servers, and how many are in trouble.
    public struct Summary: Sendable, Equatable {
        /// Distinct servers across the threads.
        public var count: Int
        public var needsAuth: Int
        public var failed: Int

        /// `3 · 1 needs auth`, `4 · 2 failed`, `3`, `none`. The trouble parts are also offered apart, for a
        /// header that tints them.
        public var text: String {
            guard count > 0 else { return "none" }
            return ([String(count)] + troubles).joined(separator: " · ")
        }

        public var troubles: [String] {
            (needsAuth > 0 ? [needsAuthText] : []) + (failed > 0 ? [failedText] : [])
        }

        public var needsAuthText: String { needsAuth == 1 ? "1 needs auth" : "\(needsAuth) need auth" }
        public var failedText: String { "\(failed) failed" }
    }

    /// Counted by name across the threads, a server in trouble in any thread counting as in trouble.
    public static func summary<ID>(_ threads: [Thread<ID>]) -> Summary {
        let merged = merged(threads.map(\.servers))
        return Summary(count: merged.count,
                       needsAuth: merged.filter { $0.status == .needsAuth }.count,
                       failed: merged.filter { $0.status == .failed }.count)
    }
}
