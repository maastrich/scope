import Foundation
import Testing
@testable import ScopeCore

private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let other = ScopeID(rawValue: "1a2b3c4d-4b6a-4c62-9c3f-2d1e7a5b9f10")

private func record(_ id: String, scope: ScopeID = acme, resident: ResidentRole? = nil) throws -> ThreadRecord {
    ThreadRecord(id: try #require(ThreadID(rawValue: id)), scopeID: scope, scopeRoot: "/scopes/acme",
                 driverID: "claude-code", title: id, cwd: "/scopes/acme", cwdKind: .scopeRoot, resident: resident)
}

@Suite struct ResidentThreadsTests {
    // MARK: Reconciliation

    @Test func everyScopeWithoutThemGetsBothOrchestratorFirst() throws {
        let result = ResidentReconciliation.reconcile([try record("aaaaaaaaaaa1")], scopes: [acme, other])
        #expect(result.missing == [.init(scopeID: acme, role: .orchestrator), .init(scopeID: acme, role: .terminal),
                                   .init(scopeID: other, role: .orchestrator), .init(scopeID: other, role: .terminal)])
        #expect(result.demoted.isEmpty)
    }

    @Test func aScopeThatHasThemGetsNothing() throws {
        let records = [try record("aaaaaaaaaaa1", resident: .orchestrator), try record("aaaaaaaaaaa2", resident: .terminal)]
        let result = ResidentReconciliation.reconcile(records, scopes: [acme])
        #expect(result.missing.isEmpty)
        #expect(result.demoted.isEmpty)
    }

    @Test func onlyTheMissingRoleIsCreated() throws {
        let result = ResidentReconciliation.reconcile([try record("aaaaaaaaaaa1", resident: .terminal)], scopes: [acme])
        #expect(result.missing == [.init(scopeID: acme, role: .orchestrator)])
    }

    @Test func aSecondClaimOnARoleIsDemotedAndTheFirstKeepsIt() throws {
        let records = [try record("aaaaaaaaaaa1", resident: .orchestrator), try record("aaaaaaaaaaa2", resident: .orchestrator),
                       try record("aaaaaaaaaaa3", scope: other, resident: .orchestrator)]
        let result = ResidentReconciliation.reconcile(records, scopes: [acme, other])
        #expect(result.demoted.map(\.rawValue) == ["aaaaaaaaaaa2"])
        #expect(result.missing == [.init(scopeID: acme, role: .terminal), .init(scopeID: other, role: .terminal)])
    }

    @Test func recordsOfUndeclaredScopesAskForNothing() throws {
        let result = ResidentReconciliation.reconcile([try record("aaaaaaaaaaa1", scope: other, resident: .orchestrator)],
                                                      scopes: [])
        #expect(result.missing.isEmpty)
        #expect(result.demoted.isEmpty)
    }

    // MARK: Record

    @Test func theRoleRoundTripsAndOldOrUnknownRecordsAreOrdinary() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let resident = try record("aaaaaaaaaaa1", resident: .terminal)
        #expect(try decoder.decode(ThreadRecord.self, from: encoder.encode(resident)).resident == .terminal)

        let ordinary = try encoder.encode(try record("aaaaaaaaaaa2"))
        #expect(!String(decoding: ordinary, as: UTF8.self).contains("resident"))
        #expect(try decoder.decode(ThreadRecord.self, from: ordinary).resident == nil)

        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(resident)) as? [String: Any])
        object["resident"] = "librarian"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(ThreadRecord.self, from: unknown).resident == nil)
    }

    // MARK: Restart

    @Test func aLongRunThatCrashesComesBackAtOnceResumed() {
        let (decision, count) = ResidentRestart.decide(ExitStatus(code: 1, signal: nil), ranFor: .seconds(600), quickExits: 2)
        #expect(decision == .restart(after: .seconds(1), fresh: false))
        #expect(count == 0)
    }

    @Test func aCleanExitStartsANewSession() {
        let (decision, _) = ResidentRestart.decide(ExitStatus(code: 0, signal: nil), ranFor: .seconds(600), quickExits: 0)
        #expect(decision == .restart(after: .seconds(1), fresh: true))
    }

    @Test func quickExitsBackOffWithoutResumingThenHold() {
        let crash = ExitStatus(code: nil, signal: 11)
        let (first, one) = ResidentRestart.decide(crash, ranFor: .seconds(2), quickExits: 0)
        #expect(first == .restart(after: .seconds(2), fresh: true))
        let (second, two) = ResidentRestart.decide(crash, ranFor: .seconds(2), quickExits: one)
        #expect(second == .restart(after: .seconds(4), fresh: true))
        let (third, three) = ResidentRestart.decide(crash, ranFor: nil, quickExits: two)
        #expect(third == .hold(.keepsExiting(3)))
        #expect(three == ResidentRestart.maxQuickExits)
    }

    @Test func aCommandThatCannotRunIsNeverRetried() {
        let (decision, count) = ResidentRestart.decide(ExitStatus(code: 127, signal: nil), ranFor: .seconds(600), quickExits: 0)
        #expect(decision == .hold(.cannotStart))
        #expect(count == 0)
    }
}
