import Foundation
import Testing
@testable import ScopeCore

@Suite struct ThreadStateTests {
    /// The whole table, written out so a change to `applying` is visible here.
    static func expected(_ state: ThreadState, _ event: ThreadStateEvent) -> ThreadState {
        if state == .exited { return .exited }
        switch event {
        case .turnStarted: return .running
        case .turnEnded: return .done
        case .turnFailed: return .failed
        case .inputRequested: return .waiting(reason: .input)
        case .permissionRequested: return .waiting(reason: .permission)
        case .threadEnded: return .done
        case .processExited: return .exited
        }
    }

    @Test func fullTransitionTable() {
        #expect(ThreadState.allCases.count == 7)
        #expect(ThreadStateEvent.allCases.count == 7)
        for state in ThreadState.allCases {
            for event in ThreadStateEvent.allCases {
                #expect(state.applying(event) == ThreadStateTests.expected(state, event), "\(state) + \(event)")
            }
        }
    }

    @Test func exitedIsAbsorbingAndOnlyReachedThroughTheProcessExit() {
        for event in ThreadStateEvent.allCases {
            #expect(ThreadState.exited.applying(event) == .exited)
        }
        for state in ThreadState.allCases where state != .exited {
            for event in ThreadStateEvent.allCases where event != .processExited {
                #expect(state.applying(event) != .exited, "\(state) + \(event)")
            }
            #expect(state.applying(.processExited) == .exited)
        }
        // thread.ended is "done", the process may still be alive.
        #expect(ThreadState.running.applying(.threadEnded) == .done)
    }

    @Test func waitingCarriesItsReason() {
        #expect(ThreadState.idle.applying(.inputRequested) == .waiting(reason: .input))
        #expect(ThreadState.idle.applying(.permissionRequested) == .waiting(reason: .permission))
        #expect(ThreadState.waiting(reason: .input).applying(.permissionRequested) == .waiting(reason: .permission))
        #expect(ThreadState.waiting(reason: .input) != ThreadState.waiting(reason: .permission))
        #expect(ThreadState.waiting(reason: .input).needsAttention)
        #expect(!ThreadState.running.needsAttention)
    }

    @Test func typicalTurn() {
        var state = ThreadState.initial
        #expect(state == .idle)
        let script: [(ThreadStateEvent, ThreadState)] = [
            (.turnStarted, .running),
            (.permissionRequested, .waiting(reason: .permission)),
            (.turnStarted, .running),
            (.inputRequested, .waiting(reason: .input)),
            (.turnStarted, .running),
            (.turnEnded, .done),
            (.threadEnded, .done),
            (.processExited, .exited),
            (.turnStarted, .exited),
        ]
        for (event, next) in script {
            state = state.applying(event)
            #expect(state == next, "\(event)")
        }
    }

    @Test func restartNormalization() {
        #expect(ThreadState.running.normalizedAfterRestart == .idle)
        #expect(ThreadState.waiting(reason: .input).normalizedAfterRestart == .idle)
        #expect(ThreadState.done.normalizedAfterRestart == .idle)
        #expect(ThreadState.failed.normalizedAfterRestart == .idle)
        #expect(ThreadState.idle.normalizedAfterRestart == .idle)
        #expect(ThreadState.exited.normalizedAfterRestart == .exited)
    }

    @Test func namesAndLabels() {
        #expect(ThreadState.allCases.map(\.name) == ["idle", "running", "waiting", "waiting", "done", "failed", "exited"])
        #expect(ThreadState.allCases.map(\.label) == [
            "Idle", "Running", "Needs your answer", "Needs permission", "Done", "Failed", "Exited",
        ])
        #expect(ThreadState.allCases.map(\.isAlive) == [true, true, true, true, true, true, false])
    }

    @Test func codableRoundTripAndShape() throws {
        for state in ThreadState.allCases {
            let data = try JSONStore.makeEncoder().encode(state)
            #expect(try JSONStore.makeDecoder().decode(ThreadState.self, from: data) == state)
        }
        let waiting = String(decoding: try JSONEncoder().encode(ThreadState.waiting(reason: .permission)), as: UTF8.self)
        #expect(waiting == #"{"waiting":{"reason":"permission"}}"#)
        let idle = String(decoding: try JSONEncoder().encode(ThreadState.idle), as: UTF8.self)
        #expect(idle == #"{"idle":{}}"#)
    }

    @Test func processPhase() {
        let alive = ProcessPhase.alive(pid: 4242, since: Date())
        #expect(alive.isAlive)
        #expect(alive.pid == 4242)
        #expect(!ProcessPhase.notStarted.isAlive)
        #expect(!ProcessPhase.launching.isAlive)
        #expect(!ProcessPhase.exited(ExitStatus(code: 0, signal: nil)).isAlive)
        #expect(!ProcessPhase.failed("no such file").isAlive)
        #expect(ProcessPhase.launching.pid == nil)
    }

    /// Marking a thread as read: the question, or the finished turn, has been seen, so the thread stops asking for
    /// attention.
    @Test func markingAsReadClearsQuestionsAndResults() {
        #expect(ThreadState.waiting(reason: .input).acknowledged == .idle)
        #expect(ThreadState.waiting(reason: .permission).acknowledged == .idle)
        #expect(ThreadState.done.acknowledged == .idle)
        #expect(ThreadState.failed.acknowledged == .idle)
        #expect(!ThreadState.waiting(reason: .input).acknowledged.needsAttention)
        for state in [ThreadState.idle, .running, .exited] {
            #expect(state.acknowledged == state, "\(state) has nothing to acknowledge")
        }
    }

    /// Only a finished turn is cleared by merely showing the thread; a question waits for its answer.
    @Test func unreadResults() {
        #expect(ThreadState.allCases.filter(\.isUnreadResult) == [.done, .failed])
        #expect(!ThreadState.failed.needsAttention)
    }

    @Test func mostUrgentOfSeveralThreads() {
        #expect(ThreadState.mostUrgent([]) == nil)
        #expect(ThreadState.mostUrgent([.idle, .running, .done]) == .running)
        #expect(ThreadState.mostUrgent([.running, .failed, .done]) == .failed)
        #expect(ThreadState.mostUrgent([.failed, .waiting(reason: .input)]) == .waiting(reason: .input))
        #expect(ThreadState.mostUrgent([.waiting(reason: .input), .waiting(reason: .permission)]) == .waiting(reason: .permission))
        #expect(ThreadState.mostUrgent([.exited, .done, .idle]) == .done)
        #expect(ThreadState.mostUrgent([.exited]) == .exited)
    }

    /// Read is not muted: the next question the driver asks brings the attention straight back.
    @Test func aNewQuestionAfterMarkingAsReadAsksAgain() {
        let read = ThreadState.waiting(reason: .input).acknowledged
        #expect(read.applying(.inputRequested).needsAttention)
        #expect(read.applying(.permissionRequested) == .waiting(reason: .permission))
    }
}

@Suite struct ExitStatusTests {
    @Test func decodesRawWaitStatus() {
        let exit3 = ExitStatus.decode(rawWaitStatus: 768)
        #expect(exit3.code == 3)
        #expect(exit3.signal == nil)
        #expect(exit3.summary == "exit 3")
        #expect(!exit3.isClean)

        let term = ExitStatus.decode(rawWaitStatus: 15)
        #expect(term.code == nil)
        #expect(term.signal == 15)
        #expect(term.summary == "killed by SIGTERM (15)")

        let hup = ExitStatus.decode(rawWaitStatus: 1)
        #expect(hup.summary == "killed by SIGHUP (1)")

        let exec = ExitStatus.decode(rawWaitStatus: 32512)
        #expect(exec.code == 127)
        #expect(exec.isExecFailure)
        #expect(exec.summary == "could not exec (127)")

        let clean = ExitStatus.decode(rawWaitStatus: 0)
        #expect(clean.isClean)
        #expect(clean.summary == "exit 0")

        let unknown = ExitStatus.decode(rawWaitStatus: nil)
        #expect(unknown.code == nil)
        #expect(unknown.signal == nil)
        #expect(unknown.summary == "unknown")
        #expect(!unknown.isClean)

        #expect(ExitStatus.decode(rawWaitStatus: 256).summary == "exit 1")
        #expect(ExitStatus.decode(rawWaitStatus: 0x7f).summary == "unknown")   // stopped, never delivered
        #expect(ExitStatus.decode(rawWaitStatus: 99).summary == "killed by signal 99 (99)")
        #expect(ExitStatus.signalName(9) == "SIGKILL")
        #expect(ExitStatus.signalName(31) == "SIGUSR2")
        #expect(ExitStatus.signalName(0) == "signal 0")
    }

    @Test func codableWithFractionalSeconds() throws {
        let status = ExitStatus(code: nil, signal: 1, at: Date(timeIntervalSince1970: 1_800_000_000.130))
        let data = try JSONStore.makeEncoder(fractionalSeconds: true).encode(status)
        #expect(String(decoding: data, as: UTF8.self).contains("\"signal\" : 1"))
        #expect(try JSONStore.makeDecoder(fractionalSeconds: true).decode(ExitStatus.self, from: data) == status)
    }
}

@Suite struct IdentifierTests {
    @Test func threadIDValidation() throws {
        #expect(ThreadID(rawValue: "3f9a2c17be04") != nil)
        #expect(ThreadID(rawValue: "3F9A2C17BE04") == nil)
        #expect(ThreadID(rawValue: "3f9a2c17be0") == nil)
        #expect(ThreadID(rawValue: "3f9a2c17be045") == nil)
        #expect(ThreadID(rawValue: "3f9a2c17bezz") == nil)
        #expect(ThreadID(rawValue: "") == nil)
        #expect(ThreadID(rawValue: "3f9a2c17bé04") == nil)

        var seen: Set<ThreadID> = []
        for _ in 0..<10_000 {
            let id = ThreadID.generate()
            #expect(ThreadID.isValid(id.rawValue))
            seen.insert(id)
        }
        #expect(seen.count == 10_000)

        let id = try #require(ThreadID(rawValue: "3f9a2c17be04"))
        #expect(String(decoding: try JSONEncoder().encode([id]), as: UTF8.self) == #"["3f9a2c17be04"]"#)
        #expect(try JSONDecoder().decode([ThreadID].self, from: Data(#"["3f9a2c17be04"]"#.utf8)) == [id])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ThreadID].self, from: Data(#"["nope"]"#.utf8))
        }
        #expect(id.description == "3f9a2c17be04")
    }

    @Test func scopeIDIsALowercaseUUIDString() throws {
        let id = ScopeID(rawValue: "8D0C1F9E-4B6A-4C62-9C3F-2D1E7A5B9F10")
        #expect(id.rawValue == "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")
        #expect(id == ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"))
        let generated = ScopeID.generate()
        #expect(UUID(uuidString: generated.rawValue) != nil)
        #expect(generated.rawValue == generated.rawValue.lowercased())
        #expect(String(decoding: try JSONEncoder().encode([id]), as: UTF8.self) == #"["8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"]"#)
        #expect(try JSONDecoder().decode([ScopeID].self, from: Data(#"["8D0C1F9E-4B6A-4C62-9C3F-2D1E7A5B9F10"]"#.utf8)) == [id])
    }
}
