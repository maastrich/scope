import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// The rules that keep the socket from turning into a fork bomb with worktrees.
@Suite struct AutomationPolicyTests {
    static let thread = ThreadID(rawValue: "3f9a2c17be04")!
    static func policy(_ settings: AutomationSettings = AutomationSettings()) -> AutomationPolicy {
        AutomationPolicy(settings: settings)
    }
    static let openThread = ControlCall.threadNew(ThreadNewParams(scope: "acme"))
    static let createTask = ControlCall.taskNew(TaskNewParams(prompt: "fix the login test"))

    @Test func readingIsAlwaysAllowed() {
        let locked = AutomationSettings(agentsMayDrive: false, depthLimit: 0, threads: .deny, tasks: .deny)
        for call in [ControlCall.ping, .list(ListParams()), .summary(SummaryParams(period: "last week")),
                     .taskShow(TaskShowParams(task: "study"))] {
            #expect(Self.policy(locked).decide(call, from: .user) == .allow)
            #expect(Self.policy(locked).decide(call, from: .thread(Self.thread, depth: 9)) == .allow)
            #expect(Self.policy(locked).decide(call, from: .strangerThread("nope")) == .allow)
        }
    }

    /// The settings hold agents in: only the user's own terminal may change them, whatever else agents may do.
    @Test func onlyTheUserChangesTheSettings() {
        let raise = ControlCall.configSet(ConfigSetParams(key: "automation.maxAgentTasks", value: "40"))
        #expect(Self.policy().decide(raise, from: .user) == .allow)
        for origin in [ControlOrigin.thread(Self.thread, depth: 0), .externalAgent(client: "scope-mcp/1"), .strangerThread("nope")] {
            guard case .refuse(let error) = Self.policy().decide(raise, from: origin) else {
                Issue.record("\(origin) may not change the settings")
                continue
            }
            #expect(error.code == .denied)
            #expect(!(error.detail ?? "").contains("unset SCOPE_THREAD") || origin == .strangerThread("nope"))
        }
        let read = ControlCall.configGet(ConfigGetParams())
        #expect(Self.policy().decide(read, from: .thread(Self.thread, depth: 0)) == .allow)
        #expect(Self.policy().decide(read, from: .externalAgent(client: "scope-mcp/1")) == .allow)
    }

    /// The base is the user's: trying a task there is refused to every agent, whatever the settings allow.
    @Test func onlyTheUserTriesATaskInTheirCheckout() {
        let open = AutomationSettings(agentsMayDrive: true, threads: .allow, tasks: .allow)
        for call in [ControlCall.taskTry(TaskTryParams(task: "auth")), .taskTry(TaskTryParams(task: "auth", end: true)),
                     .taskTry(TaskTryParams(task: "auth", refresh: true))] {
            #expect(Self.policy(open).decide(call, from: .user) == .allow)
            for origin in [ControlOrigin.thread(Self.thread, depth: 0), .externalAgent(client: "scope-mcp/1")] {
                guard case .refuse(let error) = Self.policy(open).decide(call, from: origin) else {
                    Issue.record("\(origin) may not try a task in the user's checkout")
                    continue
                }
                #expect(error.code == .denied)
            }
        }
    }

    @Test func yourOwnTerminalIsYou() {
        let locked = AutomationSettings(agentsMayDrive: false, threads: .deny, tasks: .deny)
        #expect(Self.policy(locked).decide(Self.openThread, from: .user) == .allow)
        #expect(Self.policy(locked).decide(Self.createTask, from: .user) == .allow)
    }

    /// Any task may create tasks: the default has no depth limit, at any depth.
    @Test func anAgentAtAnyDepthMayOpenWork() {
        #expect(AutomationSettings().depthLimit == nil)
        for depth in [0, 1, 2, 7, 40] {
            #expect(Self.policy().decide(Self.openThread, from: .thread(Self.thread, depth: depth)) == .allow)
            #expect(Self.policy().decide(Self.createTask, from: .thread(Self.thread, depth: depth)) == .allow)
        }
    }

    @Test func aDepthLimitIsStillAPreference() {
        let fenced = AutomationSettings(depthLimit: 3)
        #expect(Self.policy(fenced).decide(Self.createTask, from: .thread(Self.thread, depth: 2)) == .allow)
        guard case .refuse(let error) = Self.policy(fenced).decide(Self.createTask, from: .thread(Self.thread, depth: 3)) else {
            Issue.record("a depth 4 task is past a limit of 3")
            return
        }
        #expect(error.code == .denied)
        #expect(error.detail?.contains("depthLimit") == true)
    }

    @Test func aLimitOfZeroStopsAgentsEntirely() {
        let none = AutomationSettings(depthLimit: 0)
        #expect(Self.policy(none).decide(Self.openThread, from: .thread(Self.thread, depth: 0)) != .allow)
        #expect(Self.policy(none).decide(.list(ListParams()), from: .thread(Self.thread, depth: 0)) == .allow)
    }

    // MARK: Budgets

    @Test func theBudgetStopsTasksPastTheLimit() {
        let settings = AutomationSettings(maxAgentTasks: 3)
        #expect(Self.policy(settings).decide(Self.createTask, from: .thread(Self.thread, depth: 5),
                                             load: AutomationLoad(tasks: 2)) == .allow)
        guard case .refuse(let error) = Self.policy(settings).decide(Self.createTask, from: .thread(Self.thread, depth: 5),
                                                                     load: AutomationLoad(tasks: 3)) else {
            Issue.record("a fourth task is past a budget of 3")
            return
        }
        #expect(error.code == .denied)
        #expect(error.message.contains("3 tasks"))
        #expect(error.detail?.contains("scope task archive") == true)
    }

    @Test func theBudgetStopsThreadsPastTheLimit() {
        let settings = AutomationSettings(maxAgentThreads: 2)
        #expect(Self.policy(settings).decide(Self.openThread, from: .thread(Self.thread, depth: 1),
                                             load: AutomationLoad(threads: 1)) == .allow)
        guard case .refuse(let error) = Self.policy(settings).decide(Self.openThread, from: .thread(Self.thread, depth: 1),
                                                                     load: AutomationLoad(threads: 2)) else {
            Issue.record("a third thread is past a budget of 2")
            return
        }
        #expect(error.detail?.contains("scope thread close") == true)
        // A task opening its first thread needs a thread slot too; one left cold does not.
        #expect(Self.policy(settings).decide(Self.createTask, from: .thread(Self.thread, depth: 1),
                                             load: AutomationLoad(threads: 2)) != .allow)
        let cold = ControlCall.taskNew(TaskNewParams(prompt: "x", openThread: false))
        #expect(Self.policy(settings).decide(cold, from: .thread(Self.thread, depth: 1), load: AutomationLoad(threads: 2)) == .allow)
    }

    @Test func theBudgetNeverStopsYouOrADryRunOrAnAction() {
        let tight = AutomationSettings(maxAgentTasks: 1, maxAgentThreads: 1)
        let full = AutomationLoad(tasks: 50, threads: 50)
        #expect(Self.policy(tight).decide(Self.createTask, from: .user, load: full) == .allow)
        let dry = ControlCall.taskNew(TaskNewParams(prompt: "x", dryRun: true))
        #expect(Self.policy(tight).decide(dry, from: .thread(Self.thread, depth: 0), load: full) == .allow)
        let close = ControlCall.threadClose(ThreadTargetParams(thread: "x"))
        #expect(Self.policy(tight).decide(close, from: .thread(Self.thread, depth: 0), load: full) == .allow)
        let archive = ControlCall.taskArchive(TaskArchiveParams(task: "t"))
        #expect(Self.policy(tight).decide(archive, from: .thread(Self.thread, depth: 0), load: full) == .allow)
    }

    @Test func anAgentOutsideScopeSharesTheBudget() {
        let external = ControlOrigin.externalAgent(client: "scope-mcp/0.4.3")
        guard case .refuse = Self.policy(AutomationSettings(maxAgentTasks: 1)).decide(Self.createTask, from: external,
                                                                                    load: AutomationLoad(tasks: 1)) else {
            Issue.record("an agent outside Scope counts against the same budget")
            return
        }
    }

    @Test func whatACallCosts() {
        #expect(AutomationPolicy.cost(of: Self.openThread) == AutomationLoad(threads: 1))
        #expect(AutomationPolicy.cost(of: Self.createTask) == AutomationLoad(tasks: 1, threads: 1))
        #expect(AutomationPolicy.cost(of: .taskNew(TaskNewParams(prompt: "x", openThread: false))) == AutomationLoad(tasks: 1))
        #expect(AutomationPolicy.cost(of: .taskNew(TaskNewParams(prompt: "x", dryRun: true))).isZero)
        #expect(AutomationPolicy.cost(of: .list(ListParams())).isZero)
    }

    @Test func budgetsAreClampedAndDefaultSensibly() {
        #expect(AutomationSettings().maxAgentTasks == AutomationSettings.defaultMaxAgentTasks)
        #expect(AutomationSettings(maxAgentTasks: 0, maxAgentThreads: 9999).maxAgentTasks == 1)
        #expect(AutomationSettings(maxAgentTasks: 0, maxAgentThreads: 9999).maxAgentThreads == AutomationSettings.budgetRange.upperBound)
    }

    @Test func creatingATaskGoesAheadByDefault() {
        #expect(Self.policy().decide(Self.createTask, from: .thread(Self.thread, depth: 0)) == .allow)
    }

    @Test func creatingATaskAsksWhenSetTo() {
        let asking = AutomationSettings(tasks: .ask)
        guard case .ask(let subject) = Self.policy(asking).decide(Self.createTask, from: .thread(Self.thread, depth: 0)) else {
            Issue.record("tasks set to ask must ask")
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
        let json = Data(#"{"depthLimit":-4,"maxAgentTasks":"many","tasks":"whenever","approvalTimeout":1}"#.utf8)
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: json)
        #expect(settings.depthLimit == 0)
        #expect(settings.maxAgentTasks == AutomationSettings.defaultMaxAgentTasks)
        #expect(settings.tasks == .allow)        // unknown word falls back to the default
        #expect(settings.approvalTimeout >= 5)   // a one-second window is not an opportunity to answer
        #expect(settings.agentsMayDrive)
    }

    /// Settings wrote the whole block on any change, so the old default ceiling of 1 sits in many configs: it must
    /// not keep tasks from creating tasks. A 0 was a choice and stays.
    @Test func theOldCeilingIsDroppedUnlessItWasZero() throws {
        func decode(_ json: String) throws -> AutomationSettings {
            try JSONDecoder().decode(AutomationSettings.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"maxDepth":1}"#).depthLimit == nil)
        #expect(try decode(#"{"maxDepth":4}"#).depthLimit == nil)
        #expect(try decode(#"{"maxDepth":0}"#).depthLimit == 0)
        #expect(try decode(#"{"maxDepth":0,"depthLimit":2}"#).depthLimit == 2)
        // Written back, the old key is gone and the new one says what was kept.
        let reencoded = String(decoding: try JSONEncoder().encode(try decode(#"{"maxDepth":0}"#)), as: UTF8.self)
        #expect(!reencoded.contains("maxDepth"))
        #expect(try decode(reencoded).depthLimit == 0)
        let unlimited = String(decoding: try JSONEncoder().encode(AutomationSettings()), as: UTF8.self)
        #expect(try decode(unlimited).depthLimit == nil)
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
        #expect(AutomationPolicy(settings: AutomationSettings()).decide(task, from: external) == .allow)
        guard case .ask = AutomationPolicy(settings: AutomationSettings(tasks: .ask)).decide(task, from: external) else {
            Issue.record("a task from an agent outside Scope follows the tasks approval, like any agent's")
            return
        }
        guard case .refuse = AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false)).decide(open, from: external) else {
            Issue.record("turning agents off turns this one off too")
            return
        }
        guard case .refuse(let error) = AutomationPolicy(settings: AutomationSettings(depthLimit: 0)).decide(open, from: external) else {
            Issue.record("a limit of 0 stops it")
            return
        }
        #expect(error.message.contains("outside Scope"))
        #expect(AutomationPolicy.childDepth(of: external) == 1)
    }
}

/// Stopping, closing, reading and typing into threads: any thread by default, only its own when fenced.
@Suite struct ThreadOwnershipPolicyTests {
    static let agent = ThreadID(rawValue: "3f9a2c17be04")!
    static let other = ThreadID(rawValue: "aaaaaaaaaaaa")!
    static let external = ControlOrigin.externalAgent(client: "scope-mcp/0.4.3")

    static let openedByAgent = ThreadOrigin(author: .control, parent: "3f9a2c17be04", depth: 1, client: "scope-mcp/0.4.3")
    static let openedByOther = ThreadOrigin(author: .control, parent: "aaaaaaaaaaaa", depth: 1, client: "scope-mcp/0.4.3")
    static let openedOutside = ThreadOrigin(author: .control, parent: nil, depth: 1, client: "scope-mcp/0.4.3")
    static let openedByUserCLI = ThreadOrigin(author: .control, parent: nil, depth: 0, client: "scope-cli/0.4.3")
    static let every = [openedByAgent, openedByOther, openedOutside, openedByUserCLI, ThreadOrigin.user]

    @Test func theUserTouchesAnything() {
        for target in Self.every {
            #expect(AutomationPolicy.mayTouch(target, from: .user, reach: .own) == nil)
            #expect(AutomationPolicy.mayTouch(target, from: .user, reach: .any) == nil)
        }
    }

    @Test func anyThreadIsTheDefault() {
        #expect(AutomationSettings().threadReach == .any)
        for target in Self.every {
            #expect(AutomationPolicy.mayTouch(target, id: Self.other, from: .thread(Self.agent, depth: 0), reach: .any) == nil)
            #expect(AutomationPolicy.mayTouch(target, id: Self.other, from: Self.external, reach: .any) == nil)
        }
    }

    /// The one thread an agent may never type into is its own: the prompt would loop with nobody at the keyboard.
    @Test func aThreadNeverActsOnItself() {
        let refusal = AutomationPolicy.mayTouch(.user, id: Self.agent, from: .thread(Self.agent, depth: 0), reach: .any)
        #expect(refusal?.code == .badRequest)
        #expect(AutomationPolicy.mayTouch(Self.openedByAgent, id: Self.agent, from: .thread(Self.agent, depth: 0), reach: .own)?.code == .badRequest)
        // Without an id to compare there is nothing to refuse on: the old callers keep working.
        #expect(AutomationPolicy.mayTouch(Self.openedByOther, from: .thread(Self.agent, depth: 0), reach: .any) == nil)
    }

    @Test func fencedAnAgentTouchesOnlyTheThreadsItOpened() {
        #expect(AutomationPolicy.mayTouch(Self.openedByAgent, from: .thread(Self.agent, depth: 0), reach: .own) == nil)
        #expect(AutomationPolicy.mayTouch(Self.openedByOther, from: .thread(Self.agent, depth: 0), reach: .own)?.code == .denied)
        #expect(AutomationPolicy.mayTouch(.user, from: .thread(Self.agent, depth: 0), reach: .own)?.code == .denied)
    }

    /// A driver command has its own fence, `own` by default, and never a wider one than messages have.
    @Test func driverCommandsReachTheAgentsOwnThreadsUnlessOpened() throws {
        #expect(AutomationSettings().commandReach == .own)
        #expect(AutomationSettings().effectiveCommandReach == .own)
        #expect(AutomationSettings(threadReach: .any, commandReach: .any).effectiveCommandReach == .any)
        #expect(AutomationSettings(threadReach: .own, commandReach: .any).effectiveCommandReach == .own)
        let decoded = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"commandReach":"any"}"#.utf8))
        #expect(decoded.effectiveCommandReach == .any)
        #expect(try JSONDecoder().decode(AutomationSettings.self, from: Data("{}".utf8)).commandReach == .own)
        let reach = AutomationSettings().effectiveCommandReach
        #expect(AutomationPolicy.mayTouch(Self.openedByAgent, from: .thread(Self.agent, depth: 0), reach: reach) == nil)
        #expect(AutomationPolicy.mayTouch(Self.openedByOther, from: .thread(Self.agent, depth: 0), reach: reach)?.code == .denied)
        #expect(AutomationPolicy.mayTouch(.user, from: .user, reach: reach) == nil)
    }

    /// An orchestrator waits for the thread its task's agent started: `own` is everything below it, not one level.
    @Test func fencedAnAgentReachesItsDescendantsButNotItsKin() {
        let child = ThreadOrigin.child(of: Self.agent.rawValue, origin: .user, depth: 1, client: "scope-cli/1")
        let grandchild = ThreadOrigin.child(of: "bbbbbbbbbbbb", origin: child, depth: 2, client: "scope-cli/1")
        let greatGrandchild = ThreadOrigin.child(of: "cccccccccccc", origin: grandchild, depth: 3, client: "scope-cli/1")
        #expect(grandchild.lineage == ["bbbbbbbbbbbb", Self.agent.rawValue])
        #expect(AutomationPolicy.mayTouch(grandchild, from: .thread(Self.agent, depth: 0), reach: .own) == nil)
        #expect(AutomationPolicy.mayTouch(greatGrandchild, from: .thread(Self.agent, depth: 0), reach: .own) == nil)
        // A sibling: opened by the same parent as the agent, not by the agent.
        let sibling = ThreadOrigin.child(of: "dddddddddddd", origin: .user, depth: 1, client: "scope-cli/1")
        let me = ThreadID(rawValue: "eeeeeeeeeeee")!
        #expect(AutomationPolicy.mayTouch(sibling, from: .thread(me, depth: 1), reach: .own)?.code == .denied)
        // Its parent: above it, not below.
        #expect(AutomationPolicy.mayTouch(.user, id: Self.agent, from: .thread(ThreadID(rawValue: "bbbbbbbbbbbb")!, depth: 1),
                                          reach: .own)?.code == .denied)
    }

    /// A record written before lineages were kept still knows its parent.
    @Test func anOldRecordHasItsParentForLineage() throws {
        let old = try JSONDecoder().decode(ThreadOrigin.self, from: Data(#"{"author":"control","parent":"3f9a2c17be04","depth":1}"#.utf8))
        #expect(old.lineage == ["3f9a2c17be04"])
        #expect(ThreadOrigin.user.lineage.isEmpty)
    }

    @Test func aLineageIsBounded() {
        var origin = ThreadOrigin.user
        for generation in 0..<100 {
            origin = .child(of: String(format: "%012x", generation), origin: origin, depth: generation + 1, client: nil)
        }
        #expect(origin.lineage.count == ThreadOrigin.lineageLimit + 1)
    }

    @Test func fencedAnAgentOutsideScopeTouchesOnlyWhatAgentsOutsideScopeOpened() {
        #expect(AutomationPolicy.mayTouch(Self.openedOutside, from: Self.external, reach: .own) == nil)
        #expect(AutomationPolicy.mayTouch(Self.openedByUserCLI, from: Self.external, reach: .own)?.code == .denied)
        #expect(AutomationPolicy.mayTouch(Self.openedByAgent, from: Self.external, reach: .own)?.code == .denied)
        #expect(AutomationPolicy.mayTouch(.user, from: Self.external, reach: .own)?.code == .denied)
    }

    @Test func aStrangerTouchesNothingWhateverTheReach() {
        #expect(AutomationPolicy.mayTouch(Self.openedOutside, from: .strangerThread("zzz"), reach: .any)?.code == .denied)
    }

    @Test func theReachSurvivesAHalfWrittenConfig() throws {
        let decoded = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"threadReach":"sideways"}"#.utf8))
        #expect(decoded.threadReach == .any)
        let own = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"threadReach":"own"}"#.utf8))
        #expect(own.threadReach == .own)
    }

    /// Nothing new is opened, so neither the depth limit nor a full budget stops an agent from stopping its thread.
    @Test func actingOnAThreadIgnoresTheLimits() {
        let policy = AutomationPolicy(settings: AutomationSettings(depthLimit: 1, maxAgentThreads: 1))
        let stop = ControlCall.threadStop(ThreadTargetParams(thread: "x"))
        #expect(policy.decide(stop, from: .thread(Self.agent, depth: 5), load: AutomationLoad(threads: 9)) == .allow)
        #expect(policy.decide(.threadSend(ThreadSendParams(thread: "x", text: "y")), from: Self.external) == .allow)
    }

    @Test func closingATaskAsksLikeCreatingOne() {
        let close = ControlCall.taskClose(TaskCloseParams(task: "rework-auth", deleteBranch: true))
        #expect(AutomationPolicy(settings: AutomationSettings()).decide(close, from: Self.external) == .allow)
        guard case .ask(let subject) = AutomationPolicy(settings: AutomationSettings(tasks: .ask)).decide(close, from: Self.external) else {
            Issue.record("undoing a task from an agent asks the user")
            return
        }
        #expect(subject.contains("rework-auth") && subject.contains("branch"))
        #expect(AutomationPolicy(settings: AutomationSettings()).decide(close, from: .user) == .allow)
    }

    @Test func archivingAndCleaningAskLikeClosing() {
        let ask = AutomationPolicy(settings: AutomationSettings(tasks: .ask))
        guard case .ask = ask.decide(.taskArchive(TaskArchiveParams(task: "t")), from: Self.external) else {
            Issue.record("archiving a task from an agent asks the user"); return
        }
        guard case .ask = ask.decide(.gc(GCParams()), from: Self.external) else {
            Issue.record("a real cleanup from an agent asks the user"); return
        }
        // A preview only reads.
        #expect(ask.decide(.gc(GCParams(dryRun: true)), from: Self.external) == .allow)
    }

    @Test func agentsTurnedOffCannotActEither() {
        let off = AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false))
        guard case .refuse = off.decide(.threadClose(ThreadTargetParams(thread: "x")), from: .thread(Self.agent, depth: 0)) else {
            Issue.record("agents turned off means off")
            return
        }
    }

    @Test func runningAScheduleAsksLikeATaskAndMilestonesAreBookkeeping() {
        let ask = AutomationPolicy(settings: AutomationSettings(tasks: .ask))
        guard case .ask(let subject) = ask.decide(.scheduleRun(ScheduleRunParams(name: "morning")), from: Self.external) else {
            Issue.record("firing a schedule from an agent asks the user"); return
        }
        #expect(subject.contains("morning"))
        #expect(ask.decide(.scheduleList(ScheduleListParams()), from: Self.external) == .allow)
        #expect(ask.decide(.milestoneAdd(MilestoneAddParams(title: "t")), from: Self.external) == .allow)
        #expect(ask.decide(.milestoneDone(MilestoneDoneParams(milestone: "1")), from: Self.external) == .allow)
        #expect(AutomationPolicy(settings: AutomationSettings(agentsMayDrive: false))
            .decide(.milestoneDone(MilestoneDoneParams(milestone: "1")), from: Self.external) != .allow)
    }
}

/// What the receiving agent reads above a message another agent sent.
@Suite struct ThreadMessageTests {
    @Test func aThreadSignsWithItsIdTitleAndTask() {
        let sender = ThreadMessage.Sender(thread: .init(id: "3f9a2c17be04", title: "review", task: "rate-limiting"),
                                          client: "scope-cli/0.9.0")
        let text = ThreadMessage.envelope("run the tests again", from: sender)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("[Scope: message from thread 3f9a2c17be04 “review”, task rate-limiting;"))
        #expect(lines[0].contains("scope thread send 3f9a2c17be04"))
        #expect(lines[1] == "run the tests again")
    }

    @Test func anotherScopeIsNamedOnlyWhenItDiffers() {
        let near = ThreadMessage.header(for: .init(thread: .init(id: "a", title: "t"), client: "c"))
        #expect(!near.contains(", scope "))
        let far = ThreadMessage.header(for: .init(thread: .init(id: "a", title: "t", task: "x", scope: "acme"), client: "c"))
        #expect(far.contains("task x, scope acme"))
    }

    @Test func theTwoSpellingsOfTheMCPClientAgree() {
        #expect(ThreadOrigin.mcpClientPrefix == ControlClientName.mcp + "/")
    }

    /// The marker is for agents: your own terminal goes through the socket too and must not wear it.
    @Test func onlyAgentsCountAsHavingOpenedAThread() {
        #expect(!ThreadOrigin.user.openedByAgent)
        #expect(!ThreadOrigin.unknown.openedByAgent)
        #expect(!ThreadOrigin(author: .control, client: "scope-cli/0.9.0").openedByAgent)
        #expect(ThreadOrigin(author: .control, parent: "3f9a2c17be04", depth: 1, client: "scope-cli/0.9.0").openedByAgent)
        #expect(ThreadOrigin(author: .control, depth: 1, client: "scope-mcp/0.9.0").openedByAgent)
    }

    @Test func anAgentOutsideScopeHasNoThreadToAnswer() {
        let header = ThreadMessage.header(for: .init(client: "scope-mcp/0.9.0"))
        #expect(header.contains("outside Scope (scope-mcp/0.9.0)"))
        #expect(!header.contains("scope thread send"))
    }
}
