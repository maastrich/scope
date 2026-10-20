import Foundation
import Testing
@testable import ScopeAdapters

@Suite struct ConnectorsSummaryTests {
    private typealias Server = ClaudeMCPServers.Server
    private typealias Thread = ConnectorsSummary.Thread<String>

    private func connected(_ name: String, tools: Int = 3, calls: Int = 0) -> Server {
        Server(name: name, source: .user, transport: "stdio", status: .connected, isInferred: true, evidence: .toolsListed,
               toolCalls: calls, tools: tools)
    }

    private func failed(_ name: String, code: String = "CONNECTION_CLOSED") -> Server {
        Server(name: name, source: .user, transport: "stdio", status: .failed, error: "Connection closed", errorCode: code)
    }

    private func needsAuth(_ name: String) -> Server {
        Server(name: name, source: .claudeAI, status: .needsAuth, tools: 2)
    }

    private func pending(_ name: String) -> Server {
        Server(name: name, source: .project, transport: "http", status: .pending)
    }

    // MARK: Ordering

    @Test func troubleComesFirstThenConnectedByName() {
        let servers = [connected("zeta"), connected("alpha"), pending("pend"), failed("broken"), needsAuth("linear"),
                       Server(name: "declared", source: .local, status: .unknown)]
        let names = ConnectorsSummary.ordered(servers).map(\.name)
        #expect(names == ["linear", "broken", "pend", "alpha", "zeta", "declared"])
    }

    @Test func namesSortNaturallyInsideAState() {
        let names = ConnectorsSummary.ordered([connected("server10"), connected("Server2"), connected("server1")]).map(\.name)
        #expect(names == ["server1", "Server2", "server10"])
    }

    /// Claude Code never says "connected": only a listed or called tool earns the teal dot.
    @Test func connectedIsOnlyClaimedOnEvidence() {
        var quiet = connected("quiet")
        quiet.evidence = .notReported
        #expect(ConnectorsSummary.light(connected("listed")) == .connected)
        #expect(ConnectorsSummary.light(quiet) == .notReported)
        #expect(ConnectorsSummary.light(Server(name: "x", status: .unknown)) == .notReported)
        // And it sorts after the confirmed ones.
        #expect(ConnectorsSummary.ordered([quiet, connected("zz")]).map(\.name) == ["zz", "quiet"])
    }

    // MARK: Merging

    @Test func threadsThatAgreeMakeOneListWithCallsAddedUp() {
        let threads = [Thread(id: "a", title: "Fix login", servers: [connected("github", tools: 12, calls: 2), needsAuth("linear")]),
                       Thread(id: "b", title: "Review", servers: [connected("github", tools: 12, calls: 3), needsAuth("linear")])]
        let groups = ConnectorsSummary.groups(threads)
        #expect(groups.count == 1)
        #expect(groups[0].title == nil)
        #expect(groups[0].servers.map(\.name) == ["linear", "github"])
        #expect(groups[0].servers[1].toolCalls == 5)
        #expect(groups[0].servers[1].tools == 12)
    }

    @Test func threadsThatDisagreeGetOneGroupEachUnderTheirTitle() {
        let threads = [Thread(id: "a", title: "Fix login", servers: [connected("github"), connected("linear")]),
                       Thread(id: "b", title: "Review", servers: [connected("github"), failed("linear")])]
        let groups = ConnectorsSummary.groups(threads)
        #expect(groups.map(\.title) == ["Fix login", "Review"])
        #expect(groups.map(\.thread) == ["a", "b"])
        #expect(groups[1].servers.map(\.name) == ["linear", "github"])
    }

    @Test func aDifferentServerSetIsADisagreement() {
        let threads = [Thread(id: "a", title: "A", servers: [connected("github")]),
                       Thread(id: "b", title: "B", servers: [connected("github"), pending("local-db")])]
        #expect(ConnectorsSummary.groups(threads).count == 2)
    }

    /// Tool counts and calls follow each thread's own work: they never split the list.
    @Test func differentCountsAreNoDisagreement() {
        let threads = [Thread(id: "a", title: "A", servers: [connected("github", tools: 10, calls: 0)]),
                       Thread(id: "b", title: "B", servers: [connected("github", tools: 12, calls: 7)])]
        let groups = ConnectorsSummary.groups(threads)
        #expect(groups.count == 1)
        #expect(groups[0].servers[0].tools == 12)
    }

    @Test func aThreadThatKnowsNoServerYetIsLeftOut() {
        let threads = [Thread(id: "a", title: "A", servers: [connected("github")]), Thread(id: "b", title: "B", servers: [])]
        let groups = ConnectorsSummary.groups(threads)
        #expect(groups.count == 1)
        #expect(groups[0].title == nil)
        #expect(ConnectorsSummary.groups([Thread(id: "b", title: "B", servers: [])]).isEmpty)
    }

    @Test func mergingKeepsTheWorstStateAndItsError() {
        let merged = ConnectorsSummary.merged([[connected("db")], [failed("db", code: "ENOTFOUND")]])
        #expect(merged.count == 1)
        #expect(merged[0].status == .failed)
        #expect(merged[0].errorCode == "ENOTFOUND")
        #expect(merged[0].transport == "stdio")
    }

    // MARK: Summary

    @Test func theClosedHeaderCountsServersAndTrouble() {
        func text(_ servers: [Server]...) -> String {
            ConnectorsSummary.summary(servers.enumerated().map { Thread(id: "\($0.offset)", title: "t", servers: $0.element) }).text
        }
        #expect(text([]) == "none")
        #expect(text() == "none")
        #expect(text([connected("a"), connected("b"), connected("c")]) == "3")
        #expect(text([connected("a"), connected("b"), needsAuth("linear")]) == "3 · 1 needs auth")
        #expect(text([connected("a"), failed("b"), failed("c"), connected("d")]) == "4 · 2 failed")
        #expect(text([needsAuth("x"), needsAuth("y"), failed("z")]) == "3 · 2 need auth · 1 failed")
    }

    /// A server is counted once across threads, and in trouble when it is in any of them.
    @Test func theSummaryCountsByNameAcrossThreads() {
        let threads = [Thread(id: "a", title: "A", servers: [connected("github"), connected("db")]),
                       Thread(id: "b", title: "B", servers: [connected("github"), failed("db")])]
        let summary = ConnectorsSummary.summary(threads)
        #expect(summary == ConnectorsSummary.Summary(count: 2, needsAuth: 0, failed: 1))
        #expect(summary.text == "2 · 1 failed")
    }
}
