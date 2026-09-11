import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

@Suite struct ThreadStateMachineTests {
    /// The whole table, one row per (state, kind) pair.
    static let table: [(ThreadState, HookEvent.Kind, ThreadState)] = {
        // Every alive state moves the same way; only `exited` absorbs, and `session.started` moves nothing.
        let alive: [ThreadState] = [.idle, .running, .waiting(reason: .input), .waiting(reason: .permission), .done, .failed]
        let moves: [(HookEvent.Kind, ThreadState)] = [
            (.turnStarted, .running),
            (.turnEnded, .done),
            (.turnFailed, .failed),
            (.inputRequested, .waiting(reason: .input)),
            (.permissionRequested, .waiting(reason: .permission)),
            (.threadEnded, .done),
        ]
        var rows: [(ThreadState, HookEvent.Kind, ThreadState)] = []
        for state in alive {
            rows += moves.map { (state, $0.0, $0.1) }
            rows.append((state, .sessionStarted, state))
        }
        rows += HookEvent.Kind.allCases.map { (.exited, $0, .exited) }
        return rows
    }()

    @Test func tableCoversEveryStateAndKind() {
        #expect(Self.table.count == ThreadState.allCases.count * HookEvent.Kind.allCases.count)
        for state in ThreadState.allCases {
            for kind in HookEvent.Kind.allCases {
                #expect(Self.table.contains { $0.0 == state && $0.1 == kind }, "missing row for \(state) × \(kind)")
            }
        }
    }

    @Test func everyTransitionMatchesTheTable() {
        for (current, kind, expected) in Self.table {
            #expect(ThreadStateMachine.next(current, on: kind) == expected, "\(current) on \(kind)")
        }
    }

    @Test func nextAgreesWithThreadStateApplying() {
        for state in ThreadState.allCases {
            for kind in HookEvent.Kind.allCases {
                if let stateEvent = kind.stateEvent {
                    #expect(ThreadStateMachine.next(state, on: kind) == state.applying(stateEvent))
                } else {
                    #expect(ThreadStateMachine.next(state, on: kind) == state, "\(kind) must not move \(state)")
                }
            }
        }
    }

    @Test func wireKindsMapOntoStateEvents() {
        #expect(HookEvent.Kind.turnStarted.stateEvent == .turnStarted)
        #expect(HookEvent.Kind.turnEnded.stateEvent == .turnEnded)
        #expect(HookEvent.Kind.inputRequested.stateEvent == .inputRequested)
        #expect(HookEvent.Kind.permissionRequested.stateEvent == .permissionRequested)
        #expect(HookEvent.Kind.threadEnded.stateEvent == .threadEnded)
        #expect(HookEvent.Kind.sessionStarted.stateEvent == nil)
        // No wire event stands for the PTY exit.
        #expect(!HookEvent.Kind.allCases.contains { $0.stateEvent == .processExited })
    }

    @Test func onlyExitedIsAbsorbing() {
        for kind in HookEvent.Kind.allCases {
            #expect(ThreadStateMachine.next(.exited, on: kind) == .exited)
        }
        #expect(ThreadStateMachine.isAbsorbing(.exited))
        for state in ThreadState.allCases where state != .exited {
            #expect(!ThreadStateMachine.isAbsorbing(state))
        }
    }

    @Test func noAdapterEventProducesExited() {
        for state in ThreadState.allCases where state != .exited {
            for kind in HookEvent.Kind.allCases {
                #expect(ThreadStateMachine.next(state, on: kind) != .exited, "\(state) on \(kind)")
            }
        }
        // thread.ended is done, not exited: only the PTY exit callback produces exited.
        #expect(ThreadStateMachine.next(.running, on: .threadEnded) == .done)
        #expect(ThreadStateMachine.next(.waiting(reason: .permission), on: .threadEnded) == .done)
    }

    @Test func payloadReasonRefinesInputRequested() {
        let id = ThreadID.generate()
        let asPermission = AdapterEvent(threadID: id, kind: .inputRequested, payload: ["reason": "permission"])
        let asInput = AdapterEvent(threadID: id, kind: .inputRequested, payload: ["reason": "input"])
        let unsaid = AdapterEvent(threadID: id, kind: .inputRequested)
        #expect(ThreadStateMachine.next(.running, on: asPermission) == .waiting(reason: .permission))
        #expect(ThreadStateMachine.next(.running, on: asInput) == .waiting(reason: .input))
        #expect(ThreadStateMachine.next(.running, on: unsaid) == .waiting(reason: .input))
        // The payload never overrides an explicit permission event, nor revives an absorbing state.
        let permission = AdapterEvent(threadID: id, kind: .permissionRequested, payload: ["reason": "input"])
        #expect(ThreadStateMachine.next(.done, on: permission) == .waiting(reason: .permission))
        #expect(ThreadStateMachine.next(.exited, on: asPermission) == .exited)
    }

    @Test func aNotifiedPermissionNeverReplacesAQuestion() {
        let id = ThreadID.generate()
        let notified = AdapterEvent(threadID: id, kind: .permissionRequested, payload: ["via": "notification"])
        let requested = AdapterEvent(threadID: id, kind: .permissionRequested)
        #expect(ThreadStateMachine.next(.waiting(reason: .input), on: notified) == .waiting(reason: .input))
        #expect(ThreadStateMachine.next(.waiting(reason: .input), on: requested) == .waiting(reason: .permission))
        #expect(ThreadStateMachine.next(.running, on: notified) == .waiting(reason: .permission))
    }

    @Test func typicalAgentTurnSequence() {
        var state = ThreadState.initial
        let sequence: [HookEvent.Kind] = [.turnStarted, .permissionRequested, .turnStarted, .inputRequested, .turnStarted, .turnEnded, .threadEnded]
        let expected: [ThreadState] = [.running, .waiting(reason: .permission), .running, .waiting(reason: .input), .running, .done, .done]
        for (kind, want) in zip(sequence, expected) {
            state = ThreadStateMachine.next(state, on: kind)
            #expect(state == want, "after \(kind)")
        }
        // The PTY exit is applied by the session, not by an adapter event.
        state = state.applying(.processExited)
        #expect(state == .exited)
        #expect(ThreadStateMachine.next(state, on: .turnStarted) == .exited)
    }
}
