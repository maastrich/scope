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

/// `scope mcp` registered globally is reached from sessions Scope never launched: those are agents too.
@Suite struct ExternalAgentPolicyTests {
    static let mcp = ControlCaller(client: "scope-mcp/0.4.3")
    static let cli = ControlCaller(client: "scope-cli/0.4.3")
    static let known = ThreadID(rawValue: "3f9a2c17be04")!

    static func origin(_ caller: ControlCaller) -> ControlOrigin {
        AutomationPolicy.origin(of: caller) { $0 == known ? 2 : nil }
    }

    @Test func theMCPServerOutsideAThreadIsAnAgent() {
        #expect(Self.origin(Self.mcp) == .externalAgent(client: "scope-mcp/0.4.3"))
    }

    @Test func theCommandLineOutsideAThreadIsTheUser() {
        #expect(Self.origin(Self.cli) == .user)
    }

    @Test func aThreadIsResolvedFromTheAppsOwnRecords() {
        let inThread = ControlCaller(thread: "3f9a2c17be04", client: "scope-mcp/0.4.3")
        #expect(Self.origin(inThread) == .thread(Self.known, depth: 2))
        let stranger = ControlCaller(thread: "deadbeef0000", client: "scope-cli/0.4.3")
        #expect(Self.origin(stranger) == .strangerThread("deadbeef0000"))
    }

    @Test func anExternalAgentFollowsTheRulesOfAnAgent() {
        let external = ControlOrigin.externalAgent(client: "scope-mcp/0.4.3")
        let open = ControlCall.threadNew(ThreadNewParams())
        let task = ControlCall.taskNew(TaskNewParams(prompt: "x"))
        #expect(AutomationPolicy(settings: AutomationSettings()).decide(open, from: external) == .allow)
        guard case .ask = AutomationPolicy(settings: AutomationSettings()).decide(task, from: external) else {
            Issue.record("a task from an agent outside Scope must ask, like any agent's")
            return
        }
        guard case .refuse = AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false)).decide(open, from: external) else {
            Issue.record("turning agents off turns this one off too")
            return
        }
        guard case .refuse(let error) = AutomationPolicy(settings: AutomationSettings(maxDepth: 0)).decide(open, from: external) else {
            Issue.record("a ceiling of 0 stops it")
            return
        }
        #expect(error.message.contains("outside Scope"))
        #expect(AutomationPolicy.childDepth(of: external) == 1)
    }
}

/// Stopping, closing and typing into threads: an agent may touch only its own.
@Suite struct ThreadOwnershipPolicyTests {
    static let agent = ThreadID(rawValue: "3f9a2c17be04")!
    static let external = ControlOrigin.externalAgent(client: "scope-mcp/0.4.3")

    static let openedByAgent = ThreadOrigin(author: .control, parent: "3f9a2c17be04", depth: 1, client: "scope-mcp/0.4.3")
    static let openedByOther = ThreadOrigin(author: .control, parent: "aaaaaaaaaaaa", depth: 1, client: "scope-mcp/0.4.3")
    static let openedOutside = ThreadOrigin(author: .control, parent: nil, depth: 1, client: "scope-mcp/0.4.3")
    static let openedByUserCLI = ThreadOrigin(author: .control, parent: nil, depth: 0, client: "scope-cli/0.4.3")

    @Test func theUserTouchesAnything() {
        for target in [Self.openedByAgent, Self.openedByOther, Self.openedOutside, ThreadOrigin.user] {
            #expect(AutomationPolicy.mayTouch(target, from: .user) == nil)
        }
    }

    @Test func anAgentTouchesOnlyTheThreadsItOpened() {
        #expect(AutomationPolicy.mayTouch(Self.openedByAgent, from: .thread(Self.agent, depth: 0)) == nil)
        #expect(AutomationPolicy.mayTouch(Self.openedByOther, from: .thread(Self.agent, depth: 0))?.code == .denied)
        #expect(AutomationPolicy.mayTouch(.user, from: .thread(Self.agent, depth: 0))?.code == .denied)
    }

    @Test func anAgentOutsideScopeTouchesOnlyWhatAgentsOutsideScopeOpened() {
        #expect(AutomationPolicy.mayTouch(Self.openedOutside, from: Self.external) == nil)
        #expect(AutomationPolicy.mayTouch(Self.openedByUserCLI, from: Self.external)?.code == .denied)
        #expect(AutomationPolicy.mayTouch(Self.openedByAgent, from: Self.external)?.code == .denied)
        #expect(AutomationPolicy.mayTouch(.user, from: Self.external)?.code == .denied)
    }

    /// Nothing new is opened, so the depth ceiling does not stop an agent from stopping its own thread.
    @Test func actingOnAThreadIgnoresTheDepthCeiling() {
        let policy = AutomationPolicy(settings: AutomationSettings(maxDepth: 1))
        let stop = ControlCall.threadStop(ThreadTargetParams(thread: "x"))
        #expect(policy.decide(stop, from: .thread(Self.agent, depth: 5)) == .allow)
        #expect(policy.decide(.threadSend(ThreadSendParams(thread: "x", text: "y")), from: Self.external) == .allow)
    }

    @Test func closingATaskAsksLikeCreatingOne() {
        let close = ControlCall.taskClose(TaskCloseParams(task: "rework-auth", deleteBranch: true))
        guard case .ask(let subject) = AutomationPolicy(settings: AutomationSettings()).decide(close, from: Self.external) else {
            Issue.record("undoing a task from an agent asks the user")
            return
        }
        #expect(subject.contains("rework-auth") && subject.contains("branch"))
        #expect(AutomationPolicy(settings: AutomationSettings()).decide(close, from: .user) == .allow)
    }

    @Test func agentsTurnedOffCannotActEither() {
        let off = AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false))
        guard case .refuse = off.decide(.threadClose(ThreadTargetParams(thread: "x")), from: .thread(Self.agent, depth: 0)) else {
            Issue.record("agents turned off means off")
            return
        }
    }
}
