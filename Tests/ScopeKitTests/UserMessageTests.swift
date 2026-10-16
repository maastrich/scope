import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

private let acme = ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10")
private let other = ScopeID(rawValue: "1a2b3c4d-4b6a-4c62-9c3f-2d1e7a5b9f10")

private func record(_ id: String, scope: ScopeID = acme, resident: ResidentRole? = nil) throws -> ThreadRecord {
    ThreadRecord(id: try #require(ThreadID(rawValue: id)), scopeID: scope, scopeRoot: "/scopes/acme",
                 driverID: "claude-code", title: id, cwd: "/scopes/acme", cwdKind: .scopeRoot, resident: resident)
}

@Suite struct UserMessageTests {
    // MARK: Text

    @Test func lineSeparatorsBecomeNewlinesAndEdgesAreTrimmed() {
        #expect(UserMessage.normalized("  first\u{2028}second\u{2029}third \n\n") == "first\nsecond\nthird")
    }

    @Test func blankTextIsNothingToSend() {
        #expect(UserMessage.normalized(" \n\u{2028} ") == nil)
    }

    // MARK: Orchestrator

    @Test func theOrchestratorIsTheScopesResidentOfThatRole() throws {
        let records = [try record("aaaaaaaaaaa1", resident: .terminal),
                       try record("aaaaaaaaaaa2", scope: other, resident: .orchestrator),
                       try record("aaaaaaaaaaa3", resident: .orchestrator),
                       try record("aaaaaaaaaaa4")]
        #expect(UserMessage.orchestrator(of: acme, in: records)?.rawValue == "aaaaaaaaaaa3")
        #expect(UserMessage.orchestrator(of: other, in: records)?.rawValue == "aaaaaaaaaaa2")
    }

    @Test func theFirstClaimantWinsAsReconciliationKeepsIt() throws {
        let records = [try record("aaaaaaaaaaa1", resident: .orchestrator), try record("aaaaaaaaaaa2", resident: .orchestrator)]
        #expect(UserMessage.orchestrator(of: acme, in: records)?.rawValue == "aaaaaaaaaaa1")
    }

    @Test func aScopeWithoutAnAgentHasNoOrchestrator() throws {
        #expect(UserMessage.orchestrator(of: acme, in: [try record("aaaaaaaaaaa1", resident: .terminal)]) == nil)
    }

    // MARK: Palette fallback

    @Test func aQueryMatchingNothingIsOffered() {
        #expect(UserMessage.offersAsk(query: "rebase", matches: 0, hasOrchestrator: true))
    }

    @Test func aWordThatMatchesIsLeftToItsMatches() {
        #expect(!UserMessage.offersAsk(query: "new", matches: 3, hasOrchestrator: true))
    }

    @Test func aSentenceIsOfferedEvenWhenSomethingMatched() {
        #expect(UserMessage.offersAsk(query: "open a task for the login bug", matches: 2, hasOrchestrator: true))
    }

    @Test func nothingIsOfferedWithoutQueryOrOrchestrator() {
        #expect(!UserMessage.offersAsk(query: "   ", matches: 0, hasOrchestrator: true))
        #expect(!UserMessage.offersAsk(query: "rebase", matches: 0, hasOrchestrator: false))
    }

    // MARK: Started thread

    @Test func aStartingThreadTakesTheMessageOnceItTurnsBracketedPasteOn() {
        #expect(!UserMessage.canTypeIntoStartedThread(alive: false, bracketedPaste: false, waited: .seconds(30)))
        #expect(!UserMessage.canTypeIntoStartedThread(alive: true, bracketedPaste: false, waited: .seconds(1)))
        #expect(UserMessage.canTypeIntoStartedThread(alive: true, bracketedPaste: true, waited: .zero))
    }

    @Test func aProgramThatNeverTurnsItOnGetsTheMessageAfterTheTimeout() {
        #expect(UserMessage.canTypeIntoStartedThread(alive: true, bracketedPaste: false, waited: UserMessage.startupTimeout))
    }

    // MARK: Reply excerpt

    @Test func theExcerptIsTheLastNonBlankLines() {
        let reply = AgentReply(text: "One.\n\nTwo.\nThree.\n\n  Four?  \n", at: Date(timeIntervalSince1970: 100))
        #expect(UserMessage.replyExcerpt(reply, lastPromptAt: nil, lines: 3) == "Two.\nThree.\nFour?")
    }

    @Test func aReplyOlderThanTheLastPromptIsNotShown() {
        let reply = AgentReply(text: "Done.", at: Date(timeIntervalSince1970: 100))
        #expect(UserMessage.replyExcerpt(reply, lastPromptAt: Date(timeIntervalSince1970: 200)) == nil)
        #expect(UserMessage.replyExcerpt(reply, lastPromptAt: Date(timeIntervalSince1970: 50)) == "Done.")
    }

    @Test func noReplyOrABlankOneShowsNothing() {
        #expect(UserMessage.replyExcerpt(nil, lastPromptAt: nil) == nil)
        #expect(UserMessage.replyExcerpt(AgentReply(text: "\n  \n", at: .now), lastPromptAt: nil) == nil)
    }
}
