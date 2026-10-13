import Foundation
import Testing
@testable import ScopeCore

@Suite struct AgentOpenedFocusTests {
    @Test func whenIdleOnlyTakesAnEmptySceneOfTheScopeOnScreen() {
        let focus = AgentOpenedFocus.whenIdle
        #expect(focus.takesSelection(threadShown: false, sameScope: true))
        #expect(!focus.takesSelection(threadShown: true, sameScope: true))
        #expect(!focus.takesSelection(threadShown: false, sameScope: false))
    }

    @Test func neverAndAlwaysIgnoreWhatIsOnScreen() {
        for shown in [true, false] {
            for same in [true, false] {
                #expect(!AgentOpenedFocus.never.takesSelection(threadShown: shown, sameScope: same))
                #expect(AgentOpenedFocus.always.takesSelection(threadShown: shown, sameScope: same))
            }
        }
    }

    @Test func preferencesWithoutTheFieldDefaultToWhenIdle() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(preferences.agentOpenedFocus == .whenIdle)
    }

    @Test func anUnknownValueFallsBackInsteadOfFailingTheWholeConfig() throws {
        let preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"agentOpenedFocus":"sometimes"}"#.utf8))
        #expect(preferences.agentOpenedFocus == .whenIdle)
    }

    @Test func theChoiceSurvivesARoundTrip() throws {
        let data = try JSONEncoder().encode(Preferences(agentOpenedFocus: .always))
        #expect(try JSONDecoder().decode(Preferences.self, from: data).agentOpenedFocus == .always)
    }
}
