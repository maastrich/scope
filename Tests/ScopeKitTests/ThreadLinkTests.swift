import Darwin
import Foundation
import Testing
@testable import ScopeCore

@Suite struct ThreadLinkTests {
    private let session = "2743857c-08d8-4672-a149-aa11bc54013b"
    private let a = ThreadID(rawValue: "3f9a2c17be04")!
    private let b = ThreadID(rawValue: "0000000000b2")!

    private func link(_ string: String) -> ThreadLink? {
        ThreadLink(url: URL(string: string)!)
    }

    // MARK: Parsing

    @Test func parsesTheVibeIslandTemplateOnceExpanded() {
        #expect(link("scope://thread?session=\(session)&pid=65955") == ThreadLink(sessionID: session, pid: 65955))
    }

    @Test func debugSchemeAndCaseAreAccepted() {
        #expect(link("scope-debug://thread?session=abc") == ThreadLink(sessionID: "abc"))
        #expect(link("SCOPE://Thread?session=abc") == ThreadLink(sessionID: "abc"))
    }

    @Test func threadIDIsValidated() {
        #expect(link("scope://thread?id=3f9a2c17be04") == ThreadLink(threadID: a))
        #expect(link("scope://thread?id=not-an-id") == nil)
    }

    @Test func unexpandedOrEmptyPlaceholdersAreIgnored() {
        #expect(link("scope://thread?session={session_id}&pid=42") == ThreadLink(pid: 42))
        #expect(link("scope://thread?session=&pid=") == nil)
        #expect(link("scope://thread?session=%7Bsession_id%7D") == nil)
    }

    @Test func pidMustBeAPlausibleProcess() {
        #expect(link("scope://thread?pid=1") == nil)
        #expect(link("scope://thread?pid=0") == nil)
        #expect(link("scope://thread?pid=abc") == nil)
    }

    @Test func otherSchemesHostsAndFilesAreNotLinks() {
        #expect(link("scope://task?session=abc") == nil)
        #expect(link("claude://resume?session=abc") == nil)
        #expect(ThreadLink(url: URL(fileURLWithPath: "/tmp")) == nil)
        #expect(link("scope://thread") == nil)
    }

    // MARK: Resolution

    private func candidates(aPID: pid_t? = 100, bPID: pid_t? = 200) -> [ThreadLink.Candidate] {
        [.init(id: a, sessionID: "sa", pid: aPID), .init(id: b, sessionID: session, pid: bPID)]
    }

    private func noParent(_: pid_t) -> pid_t? { nil }

    @Test func sessionPicksItsThread() {
        #expect(ThreadLink(sessionID: session).resolve(candidates(), parent: noParent) == b)
    }

    @Test func sessionBeatsPID() {
        #expect(ThreadLink(sessionID: session, pid: 100).resolve(candidates(), parent: noParent) == b)
    }

    @Test func explicitThreadIDBeatsEverything() {
        #expect(ThreadLink(threadID: a, sessionID: session).resolve(candidates(), parent: noParent) == a)
    }

    @Test func unknownThreadIDFallsBackToSession() {
        let unknown = ThreadID(rawValue: "ffffffffffff")!
        #expect(ThreadLink(threadID: unknown, sessionID: session).resolve(candidates(), parent: noParent) == b)
    }

    @Test func runningThreadWinsASharedSession() {
        let list: [ThreadLink.Candidate] = [.init(id: a, sessionID: session, pid: nil), .init(id: b, sessionID: session, pid: 7)]
        #expect(ThreadLink(sessionID: session).resolve(list, parent: noParent) == b)
    }

    @Test func unknownSessionFallsBackToPID() {
        #expect(ThreadLink(sessionID: "gone", pid: 200).resolve(candidates(), parent: noParent) == b)
    }

    @Test func pidClimbsToThePTYChild() {
        // 300 (claude) → 250 (login shell) → 100 (the PTY child of thread a)
        let tree: [pid_t: pid_t] = [300: 250, 250: 100, 100: 1]
        #expect(ThreadLink(pid: 300).resolve(candidates(), parent: { tree[$0] }) == a)
    }

    @Test func pidOutsideEveryThreadMatchesNothing() {
        let tree: [pid_t: pid_t] = [300: 250, 250: 1]
        #expect(ThreadLink(pid: 300).resolve(candidates(), parent: { tree[$0] }) == nil)
    }

    @Test func aParentCycleStops() {
        #expect(ThreadLink(pid: 300).resolve(candidates(), parent: { $0 == 300 ? 301 : 300 }) == nil)
    }

    @Test func nothingMatchesNothing() {
        #expect(ThreadLink(sessionID: "gone").resolve(candidates(), parent: noParent) == nil)
        #expect(ThreadLink(sessionID: session).resolve([], parent: noParent) == nil)
    }

    @Test func parentPIDReadsTheKernel() {
        #expect(ThreadLink.parentPID(of: getpid()) == getppid())
    }
}
