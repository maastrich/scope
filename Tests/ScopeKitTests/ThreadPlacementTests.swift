import Foundation
import Testing
@testable import ScopeCore

@Suite struct ThreadPlacementTests {
    private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")

    private func record(taskID: String? = nil, resident: ResidentRole? = nil) -> ThreadRecord {
        var record = ThreadRecord(scopeID: acme, scopeRoot: "/scopes/acme", driverID: "claude-code", title: "acme",
                                  cwd: "/scopes/acme", cwdKind: .scopeRoot)
        record.taskID = taskID
        record.resident = resident
        return record
    }

    @Test func whatATurnRewritesLeavesThePlacementAlone() {
        var record = record(taskID: "fix-login")
        let before = ThreadPlacement(record)
        record.lastState = .running
        record.resumeID = "session-1"
        record.processAlive = true
        record.lastLaunchedAt = .now
        record.launchCount += 1
        #expect(ThreadPlacement(record) == before)
    }

    @Test func movingTheThreadMovesThePlacement() {
        var record = record()
        let before = ThreadPlacement(record)
        record.taskID = "fix-login"
        #expect(ThreadPlacement(record) != before)
        #expect(ThreadPlacement(record).taskID == "fix-login")
    }

    @Test func onlyAThreadOutsideAnyTaskAndRoleIsLoose() {
        #expect(ThreadPlacement(record()).isLoose)
        #expect(!ThreadPlacement(record(taskID: "fix-login")).isLoose)
        #expect(!ThreadPlacement(record(resident: .orchestrator)).isLoose)
    }
}
