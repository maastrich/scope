import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// The two rules that keep the socket from turning into a fork bomb with worktrees.
@Suite struct AutomationPolicyTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!
    static func policy(_ settings: AutomationSettings = AutomationSettings()) -> AutomationPolicy {
        AutomationPolicy(settings: settings)
    }
    static let openThread = ControlCall.threadNew(ThreadNewParams(scope: "acme"))
    static let createTask = ControlCall.taskNew(TaskNewParams(prompt: "fix the login test"))

    @Test func readingIsAlwaysAllowed() {
        let locked = AutomationSettings(agentsMayDrive: false, maxDepth: 0, threads: .deny, tasks: .deny)
        for call in [ControlCall.ping, .list(ListParams())] {
            #expect(Self.policy(locked).decide(call, from: .user) == .allow)
            #expect(Self.policy(locked).decide(call, from: .thread(Self.thread, depth: 9)) == .allow)
            #expect(Self.policy(locked).decide(call, from: .strangerThread("nope")) == .allow)
        }
    }

    @Test func yourOwnTerminalIsYou() {
        let locked = AutomationSettings(agentsMayDrive: false, threads: .deny, tasks: .deny)
        #expect(Self.policy(locked).decide(Self.openThread, from: .user) == .allow)
        #expect(Self.policy(locked).decide(Self.createTask, from: .user) == .allow)
    }

    /// The default: a thread you opened may open one; the thread it opened may not.
    @Test func anAgentOpensOneGenerationAndNoMore() {
        #expect(Self.policy().decide(Self.openThread, from: .thread(Self.thread, depth: 0)) == .allow)
        guard case .refuse(let error) = Self.policy().decide(Self.openThread, from: .thread(Self.thread, depth: 1)) else {
            Issue.record("depth 1 should not be able to open depth 2")
            return
        }
        #expect(error.code == .denied)
    }

    @Test func theCeilingIsAPreference() {
        let deeper = AutomationSettings(maxDepth: 3)
        #expect(Self.policy(deeper).decide(Self.openThread, from: .thread(Self.thread, depth: 2)) == .allow)
        #expect(Self.policy(deeper).decide(Self.openThread, from: .thread(Self.thread, depth: 3)) != .allow)
    }

    @Test func aCeilingOfZeroStopsAgentsEntirely() {
        let none = AutomationSettings(maxDepth: 0)
        #expect(Self.policy(none).decide(Self.openThread, from: .thread(Self.thread, depth: 0)) != .allow)
        #expect(Self.policy(none).decide(.list(ListParams()), from: .thread(Self.thread, depth: 0)) == .allow)
    }

    @Test func creatingATaskAsksByDefault() {
        guard case .ask(let subject) = Self.policy().decide(Self.createTask, from: .thread(Self.thread, depth: 0)) else {
            Issue.record("a task writes branches and worktrees; it should ask")
            return
        }
        #expect(subject.contains("fix the login test"))
    }

    @Test func aThreadNobodyKnowsIsRefused() {
        guard case .refuse(let error) = Self.policy().decide(Self.openThread, from: .strangerThread("deadbeef0000")) else {
            Issue.record("an unknown SCOPE_THREAD must not open threads")
            return
        }
        #expect(error.code == .denied)
        #expect(error.detail?.contains("deadbeef0000") == true)
    }

    @Test func theSwitchTurnsEverythingOffForAgentsOnly() {
        let off = AutomationSettings(agentsMayDrive: false)
        #expect(Self.policy(off).decide(Self.openThread, from: .thread(Self.thread, depth: 0)) != .allow)
        #expect(Self.policy(off).decide(Self.openThread, from: .user) == .allow)
    }

    @Test func depthCountsGenerations() {
        #expect(AutomationPolicy.childDepth(of: .user) == 0)
        #expect(AutomationPolicy.childDepth(of: .thread(Self.thread, depth: 0)) == 1)
        #expect(AutomationPolicy.childDepth(of: .thread(Self.thread, depth: 4)) == 5)
    }

    @Test func settingsSurviveAHalfWrittenConfig() throws {
        let json = Data(#"{"maxDepth":-4,"tasks":"whenever","approvalTimeout":1}"#.utf8)
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: json)
        #expect(settings.maxDepth == 0)
        #expect(settings.tasks == .ask)          // unknown word falls back to the default
        #expect(settings.approvalTimeout >= 5)   // a one-second window is not an opportunity to answer
        #expect(settings.agentsMayDrive)
    }

    @Test func preferencesWithoutAnAutomationBlockUseTheDefaults() throws {
        let json = Data(#"{"defaultDriverID":"shell"}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: json)
        #expect(preferences.automation == nil)
        #expect(preferences.automationSettings == AutomationSettings())
    }
}
