import Foundation
import Testing
@testable import ScopeCore
@testable import ScopeGit
@testable import ScopeTasks

private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let beta = ScopeID(rawValue: "1a2b3c4d-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let gamma = ScopeID(rawValue: "2a2b3c4d-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func thread(_ id: String, _ state: ThreadState, at minutes: Double) -> Inbox.ThreadInput {
    Inbox.ThreadInput(id: ThreadID(rawValue: id)!, scopeID: acme, title: "thread \(id.prefix(2))", state: state,
                      since: t0.addingTimeInterval(minutes * 60))
}

@Suite struct QuickPanelTests {
    @Test func landsOnInboxOnlyWhileSomethingWaits() {
        #expect(QuickPanel.openingTab(waiting: 0, landing: .inboxWhenWaiting) == .ask)
        #expect(QuickPanel.openingTab(waiting: 2, landing: .inboxWhenWaiting) == .inbox)
        #expect(QuickPanel.openingTab(waiting: 2, landing: .ask) == .ask)
        #expect(QuickPanel.openingTab(waiting: 0, landing: .inbox) == .inbox)
    }

    @Test func theChosenScopeWinsWhileItExists() {
        let scopes = [acme, beta]
        #expect(QuickPanel.addressedScope(chosen: beta, current: acme, scopes: scopes) == beta)
        #expect(QuickPanel.addressedScope(chosen: gamma, current: acme, scopes: scopes) == acme)
        #expect(QuickPanel.addressedScope(chosen: nil, current: beta, scopes: scopes) == beta)
        #expect(QuickPanel.addressedScope(chosen: nil, current: gamma, scopes: scopes) == acme)
        #expect(QuickPanel.addressedScope(chosen: nil, current: nil, scopes: []) == nil)
    }

    @Test func controlDigitsFollowTheDeclaredOrder() {
        let scopes = [acme, beta]
        #expect(QuickPanel.scope(forDigit: 1, in: scopes) == acme)
        #expect(QuickPanel.scope(forDigit: 2, in: scopes) == beta)
        #expect(QuickPanel.scope(forDigit: 3, in: scopes) == nil)
        #expect(QuickPanel.scope(forDigit: 0, in: scopes) == nil)
    }

    @Test func theWindowChordHidesOnlyWhatIsAlreadyInFront() {
        #expect(QuickPanel.windowToggle(appActive: true, windowVisible: true) == .hide)
        #expect(QuickPanel.windowToggle(appActive: true, windowVisible: false) == .show)
        #expect(QuickPanel.windowToggle(appActive: false, windowVisible: true) == .show)
        #expect(QuickPanel.windowToggle(appActive: false, windowVisible: false) == .show)
    }

    @Test func theInboxTabPutsQuestionsFirstThenNewestFirst() {
        let items = Inbox.items(threads: [
            thread("aaaaaaaaaaa1", .done, at: 9),
            thread("aaaaaaaaaaa2", .waiting(reason: .input), at: 1),
            thread("aaaaaaaaaaa3", .failed, at: 5),
            thread("aaaaaaaaaaa4", .waiting(reason: .permission), at: 3),
        ], tasks: [], now: t0)
        let ordered = Inbox.urgentFirst(items)
        #expect(ordered.map(\.kind) == [.permission, .question, .reply, .failure])
        #expect(Inbox.urgentFirst([]).isEmpty)
    }
}
