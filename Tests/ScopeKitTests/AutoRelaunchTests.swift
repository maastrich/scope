import Foundation
import Testing
@testable import ScopeCore

private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let other = ScopeID(rawValue: "1a2b3c4d-4b6a-4c62-9c3f-2d1e7a5b9f10")

private func record(_ id: String, scope: ScopeID = acme, task: String? = nil, alive: Bool = true,
                    cwd: String = "/scopes/acme", driver: String = "claude-code") throws -> ThreadRecord {
    var record = ThreadRecord(
        id: try #require(ThreadID(rawValue: id)),
        scopeID: scope,
        scopeRoot: "/scopes/acme",
        driverID: driver,
        title: id,
        cwd: cwd,
        cwdKind: task.map { .task(slug: $0) } ?? .scopeRoot,
        taskID: task
    )
    record.processAlive = alive
    return record
}

private func everythingExists(_ path: String) -> Bool { true }

@Suite struct AutoRelaunchTests {
    // MARK: Which threads

    @Test func onlyThreadsThatWereRunningAreConsidered() throws {
        let plan = AutoRelaunchPlanner.plan(
            [.init(record: try record("aaaaaaaaaaa1")), .init(record: try record("aaaaaaaaaaa2", alive: false))],
            enabled: true, skippedOnce: false, pathExists: everythingExists
        )
        #expect(plan.launches.map(\.rawValue) == ["aaaaaaaaaaa1"])
        #expect(plan.skipped.isEmpty)
        #expect(plan.considered.map(\.rawValue) == ["aaaaaaaaaaa1"])
    }

    @Test func theSettingAndShiftSkipEverythingWithoutReportingIt() throws {
        let candidates: [AutoRelaunchCandidate] = [.init(record: try record("aaaaaaaaaaa1")),
                                                   .init(record: try record("aaaaaaaaaaa2"), scopeDeclared: false)]
        let off = AutoRelaunchPlanner.plan(candidates, enabled: false, skippedOnce: false, pathExists: everythingExists)
        #expect(off.launches.isEmpty)
        #expect(off.skipped.map(\.skip) == [.disabled, .disabled])
        #expect(off.blocked.isEmpty)
        #expect(off.considered.count == 2)

        let shift = AutoRelaunchPlanner.plan(candidates, enabled: true, skippedOnce: true, pathExists: everythingExists)
        #expect(shift.launches.isEmpty)
        #expect(shift.skipped.map(\.skip) == [.skippedOnce, .skippedOnce])
        #expect(shift.blocked.isEmpty)
    }

    @Test func aThreadCanOptOut() throws {
        var optedOut = try record("aaaaaaaaaaa1")
        optedOut.relaunchesAtStartup = false
        let plan = AutoRelaunchPlanner.plan([.init(record: optedOut)], enabled: true, skippedOnce: false,
                                            pathExists: everythingExists)
        #expect(plan.launches.isEmpty)
        #expect(plan.skipped.map(\.skip) == [.optedOut])
        #expect(plan.blocked.isEmpty)
    }

    // MARK: Why not

    @Test func goneScopesTasksDirectoriesAndDriversBlockTheRelaunch() throws {
        let candidates: [AutoRelaunchCandidate] = [
            .init(record: try record("aaaaaaaaaaa1"), scopeDeclared: false),
            .init(record: try record("aaaaaaaaaaa2", task: "t1"), task: .closed),
            .init(record: try record("aaaaaaaaaaa3", task: "t2"), task: .archived),
            .init(record: try record("aaaaaaaaaaa4", cwd: "/scopes/acme/gone")),
            .init(record: try record("aaaaaaaaaaa5", driver: "aider"), driverInstalled: false),
            .init(record: try record("aaaaaaaaaaa6", task: "t3"), task: .active),
        ]
        let plan = AutoRelaunchPlanner.plan(candidates, enabled: true, skippedOnce: false) { $0 != "/scopes/acme/gone" }
        #expect(plan.launches.map(\.rawValue) == ["aaaaaaaaaaa6"])
        #expect(plan.blocked.map(\.skip) == [
            .scopeUndeclared, .taskClosed, .taskArchived, .cwdMissing("/scopes/acme/gone"), .driverMissing("aider"),
        ])
        #expect(plan.blocked.allSatisfy { !$0.skip.reason.isEmpty })
    }

    @Test func aMissingScopeFolderIsNamedRatherThanEachDirectory() throws {
        let plan = AutoRelaunchPlanner.plan([.init(record: try record("aaaaaaaaaaa1"))], enabled: true,
                                            skippedOnce: false) { _ in false }
        #expect(plan.skipped.map(\.skip) == [.scopeMissing("/scopes/acme")])
    }

    // MARK: Order

    @Test func theFocusedThreadStartsFirstThenItsNeighbours() throws {
        let candidates: [AutoRelaunchCandidate] = try [
            ("aaaaaaaaaaa1", acme, nil),
            ("aaaaaaaaaaa2", other, nil),
            ("aaaaaaaaaaa3", acme, "t1"),
            ("aaaaaaaaaaa4", acme, nil),
            ("aaaaaaaaaaa5", acme, "t1"),
        ].map { .init(record: try record($0.0, scope: $0.1, task: $0.2), task: $0.2 == nil ? .none : .active) }

        let byTask = AutoRelaunchPlanner.plan(candidates, enabled: true, skippedOnce: false,
                                              focus: ThreadID(rawValue: "aaaaaaaaaaa5"), pathExists: everythingExists)
        #expect(byTask.launches.map(\.rawValue) == ["aaaaaaaaaaa5", "aaaaaaaaaaa3", "aaaaaaaaaaa1", "aaaaaaaaaaa2", "aaaaaaaaaaa4"])

        // A scope-level thread's neighbours are the other scope-level threads of that scope, not its tasks.
        let byScope = AutoRelaunchPlanner.plan(candidates, enabled: true, skippedOnce: false,
                                               focus: ThreadID(rawValue: "aaaaaaaaaaa4"), pathExists: everythingExists)
        #expect(byScope.launches.map(\.rawValue) == ["aaaaaaaaaaa4", "aaaaaaaaaaa1", "aaaaaaaaaaa2", "aaaaaaaaaaa3", "aaaaaaaaaaa5"])

        // No focus, or a focus that is not being relaunched: the order given.
        let none = AutoRelaunchPlanner.plan(candidates, enabled: true, skippedOnce: false,
                                            focus: ThreadID(rawValue: "bbbbbbbbbbbb"), pathExists: everythingExists)
        #expect(none.launches.map(\.rawValue) == ["aaaaaaaaaaa1", "aaaaaaaaaaa2", "aaaaaaaaaaa3", "aaaaaaaaaaa4", "aaaaaaaaaaa5"])
    }

    // MARK: Persistence

    @Test func olderRecordsDeriveProcessAliveFromTheirLastState() throws {
        func decode(_ lastState: String?) throws -> ThreadRecord {
            let state = lastState.map { #", "lastState": {"\#($0)": {}}"# } ?? ""
            let json = #"{"version": 1, "id": "aaaaaaaaaaa1", "scopeID": "\#(acme.rawValue)", "driverID": "shell", "cwd": "/x"\#(state)}"#
            return try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadRecord.self, from: Data(json.utf8))
        }
        #expect(try decode("running").processAlive)
        #expect(try decode("idle").processAlive)
        #expect(try !decode("exited").processAlive)
        #expect(try !decode(nil).processAlive)
        #expect(try decode(nil).relaunchesAtStartup)
    }

    @Test func theNewFieldsRoundTrip() throws {
        var original = try record("aaaaaaaaaaa1", alive: false)
        original.relaunchesAtStartup = false
        original.lastState = .running
        let data = try JSONStore.makeEncoder(fractionalSeconds: true).encode(original)
        let decoded = try JSONStore.makeDecoder(fractionalSeconds: true).decode(ThreadRecord.self, from: data)
        // The stored value wins over the one `lastState` would suggest.
        #expect(!decoded.processAlive)
        #expect(!decoded.relaunchesAtStartup)
    }

    @Test func autoRelaunchIsOnByDefault() throws {
        #expect(Preferences.default.autoRelaunchThreads)
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(decoded.autoRelaunchThreads)
        let off = try JSONDecoder().decode(Preferences.self, from: Data(#"{"autoRelaunchThreads": false}"#.utf8))
        #expect(!off.autoRelaunchThreads)
    }
}
