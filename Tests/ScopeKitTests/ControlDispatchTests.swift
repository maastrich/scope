import Foundation
import ScopeCore
import Testing
@testable import ScopeControl

/// Decode → policy → app, without a socket and without an app: the path every request takes.
@Suite @MainActor struct ControlDispatchTests {
    /// An app that records what it was asked and answers what it was told to answer.
    final class ServiceDouble: ControlService {
        var automation: AutomationSettings
        var resolved: ControlOrigin
        var approval: Bool
        var performed: [ControlCall] = []
        var confirmations: [String] = []
        var answer: Result<ControlResultPayload, ControlError>
        var agentLoad = AutomationLoad.zero
        let reservations = AutomationReservations()
        /// How long `perform` takes, standing in for a proposal and a worktree.
        var workTime: Duration = .zero
        /// What agents hold while the work is being done, seen from inside `perform`.
        var heldDuringWork: [AutomationLoad] = []
        /// What `finished` was told, one per answered request.
        var outcomes: [(method: String, outcome: ControlOutcome, seconds: TimeInterval)] = []

        init(automation: AutomationSettings = AutomationSettings(), resolved: ControlOrigin = .user,
             approval: Bool = true,
             answer: Result<ControlResultPayload, ControlError> = .success(.ping(PingResult(
                app: "Scope", version: "test", home: "/tmp", automation: AutomationSettings())))) {
            self.automation = automation
            self.resolved = resolved
            self.approval = approval
            self.answer = answer
        }

        func origin(for caller: ControlCaller) -> ControlOrigin { resolved }

        func confirm(_ subject: String, from origin: ControlOrigin, caller: ControlCaller) async -> Bool {
            confirmations.append(subject)
            return approval
        }

        func perform(_ call: ControlCall, from origin: ControlOrigin, caller: ControlCaller,
                     progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError> {
            performed.append(call)
            heldDuringWork.append(reservations.pending)
            if workTime > .zero { try? await Task.sleep(for: workTime) }
            return answer
        }

        func finished(_ request: ControlRequest, from origin: ControlOrigin, outcome: ControlOutcome, seconds: TimeInterval) {
            outcomes.append((request.method.rawValue, outcome, seconds))
        }
    }

    static let caller = ControlCaller(client: "test/1")
    static func body(_ call: ControlCall) throws -> Data {
        try ControlRequest(id: "abcd", caller: caller, call: call).encoded()
    }

    @Test func anAllowedCallReachesTheApp() async throws {
        let service = ServiceDouble()
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(.ping)), service: service, progress: { _ in })
        #expect(response.ok)
        #expect(response.id == "abcd")
        #expect(service.performed == [.ping])
    }

    @Test func aRefusedCallNeverReachesTheApp() async throws {
        let service = ServiceDouble(resolved: .strangerThread("deadbeef0000"))
        let call = ControlCall.threadNew(ThreadNewParams(scope: "acme"))
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(call)), service: service, progress: { _ in })
        #expect(!response.ok)
        #expect(response.error?.code == .denied)
        #expect(service.performed.isEmpty)
    }

    /// Tasks go ahead without asking by default; "After asking" is still a setting, and this is its path.
    static let askForTasks = AutomationSettings(tasks: .ask)

    @Test func anApprovedCallIsAskedForFirst() async throws {
        let service = ServiceDouble(automation: Self.askForTasks,
                                    resolved: .thread(ThreadID(rawValue: "3f9a2c17be04")!, depth: 0))
        let call = ControlCall.taskNew(TaskNewParams(prompt: "rework auth"))
        var progress: [String] = []
        let box = ProgressBox()
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(call)), service: service,
                                                 progress: { box.append($0) })
        progress = box.all
        #expect(response.ok)
        #expect(service.confirmations.count == 1)
        #expect(service.performed.count == 1)
        #expect(progress.contains { $0.contains("approve") })
    }

    @Test func aRefusedApprovalIsDenied() async throws {
        let service = ServiceDouble(automation: Self.askForTasks,
                                    resolved: .thread(ThreadID(rawValue: "3f9a2c17be04")!, depth: 0), approval: false)
        let call = ControlCall.taskNew(TaskNewParams(prompt: "rework auth"))
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(call)), service: service, progress: { _ in })
        #expect(response.error?.code == .denied)
        #expect(service.performed.isEmpty)
    }

    static let agent = ControlOrigin.thread(ThreadID(rawValue: "3f9a2c17be04")!, depth: 3)

    @Test func theAppsCountOfAgentWorkIsTheBudget() async throws {
        let service = ServiceDouble(automation: AutomationSettings(maxAgentTasks: 2), resolved: Self.agent)
        service.agentLoad = AutomationLoad(tasks: 2)
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(.taskNew(TaskNewParams(prompt: "x")))),
                                                 service: service, progress: { _ in })
        #expect(response.error?.code == .denied)
        #expect(service.performed.isEmpty)
    }

    /// Creating a task takes seconds: two sent together must not both take the last slot.
    @Test func requestsInFlightHoldTheirShare() async throws {
        let service = ServiceDouble(automation: AutomationSettings(maxAgentTasks: 1), resolved: Self.agent)
        service.workTime = .milliseconds(300)
        let call = ControlCall.taskNew(TaskNewParams(prompt: "x"))
        let body = try Self.body(call)
        let first = Task { await ControlDispatch.run(ControlRequest.decode(body), service: service, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(50))
        let second = await ControlDispatch.run(ControlRequest.decode(body), service: service, progress: { _ in })
        #expect(second.error?.code == .denied)
        #expect(await first.value.ok)
        #expect(service.performed.count == 1)
        #expect(service.heldDuringWork == [AutomationLoad(tasks: 1, threads: 1)])
        #expect(service.reservations.pending.isZero)
    }

    /// The user is not an agent: nothing reserved, nothing refused.
    @Test func yourOwnRequestsHoldNothing() async throws {
        let service = ServiceDouble(automation: AutomationSettings(maxAgentTasks: 1))
        service.agentLoad = AutomationLoad(tasks: 40)
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(.taskNew(TaskNewParams(prompt: "x")))),
                                                 service: service, progress: { _ in })
        #expect(response.ok)
        #expect(service.heldDuringWork == [.zero])
    }

    /// The user may take a while to answer; what was created meanwhile counts when they do.
    @Test func theBudgetIsCheckedAgainAfterTheUserApproves() async throws {
        let service = ServiceDouble(automation: AutomationSettings(maxAgentTasks: 1, tasks: .ask), resolved: Self.agent)
        let gate = ApprovalThatFillsTheBudget(service: service)
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(.taskNew(TaskNewParams(prompt: "x")))),
                                                 service: gate, progress: { _ in })
        #expect(response.error?.code == .denied)
        #expect(response.error?.message.contains("tasks open") == true)
        #expect(service.performed.isEmpty)
    }

    /// Approves, and by the time it does another task exists.
    final class ApprovalThatFillsTheBudget: ControlService {
        let service: ServiceDouble
        init(service: ServiceDouble) { self.service = service }
        var automation: AutomationSettings { service.automation }
        var agentLoad: AutomationLoad { service.agentLoad }
        var reservations: AutomationReservations { service.reservations }
        func origin(for caller: ControlCaller) -> ControlOrigin { service.resolved }
        func confirm(_ subject: String, from origin: ControlOrigin, caller: ControlCaller) async -> Bool {
            service.agentLoad = AutomationLoad(tasks: 1)
            return true
        }
        func perform(_ call: ControlCall, from origin: ControlOrigin, caller: ControlCaller,
                     progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError> {
            await service.perform(call, from: origin, caller: caller, progress: progress)
        }
    }

    @Test func aBrokenRequestIsAnsweredNotDropped() async {
        let response = await ControlDispatch.run(ControlRequest.decode(Data("{".utf8)), service: ServiceDouble(), progress: { _ in })
        #expect(response.error?.code == .badRequest)
        #expect(response.kind == .result)
    }

    @Test func aRequestBeforeTheAppIsReadyIsAnswered() async throws {
        let response = await ControlDispatch.run(ControlRequest.decode(try Self.body(.ping)), service: nil, progress: { _ in })
        #expect(response.error?.code == .failed)
        #expect(response.id == "abcd")
    }

    /// Progress lines arrive on whatever thread the app is on.
    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    // MARK: Outcomes, for the event journal

    @Test func everyAnsweredRequestReportsHowItEndedAndHowLong() async throws {
        let service = ServiceDouble()
        service.workTime = .milliseconds(20)
        _ = await ControlDispatch.run(ControlRequest.decode(try Self.body(.ping)), service: service, progress: { _ in })
        #expect(service.outcomes.count == 1)
        #expect(service.outcomes.first?.method == "ping")
        #expect(service.outcomes.first?.outcome == .ok)
        #expect((service.outcomes.first?.seconds ?? 0) >= 0.02)
    }

    @Test func aPolicyRefusalIsReportedWithItsRuleThoughTheAppNeverRanIt() async throws {
        let service = ServiceDouble(resolved: .strangerThread("deadbeef0000"))
        _ = await ControlDispatch.run(ControlRequest.decode(try Self.body(.threadNew(ThreadNewParams(scope: "acme")))),
                                      service: service, progress: { _ in })
        #expect(service.performed.isEmpty)
        #expect(service.outcomes.map(\.outcome) == [ControlOutcome(status: .refused, cause: "stranger-thread")])
    }

    @Test func aDeclinedApprovalIsReportedAsNotApproved() async throws {
        var settings = AutomationSettings()
        settings.threads = .ask
        let service = ServiceDouble(automation: settings, resolved: .thread(ThreadID(rawValue: "aaaaaaaaaaaa")!, depth: 0),
                                    approval: false)
        _ = await ControlDispatch.run(ControlRequest.decode(try Self.body(.threadNew(ThreadNewParams(scope: "acme")))),
                                      service: service, progress: { _ in })
        #expect(service.outcomes.map(\.outcome) == [ControlOutcome(status: .refused, cause: "not-approved")])
    }

    @Test func anAppFailureIsReportedByItsCodeNotItsMessage() async throws {
        let service = ServiceDouble(answer: .failure(.notFound("no task “secret-plan” in /Users/me/work")))
        _ = await ControlDispatch.run(ControlRequest.decode(try Self.body(.ping)), service: service, progress: { _ in })
        #expect(service.outcomes.map(\.outcome) == [ControlOutcome(status: .error, cause: "not_found")])
    }

    @Test func theRefusalRuleNeverTravelsOnTheWire() throws {
        let error = ControlError.denied("agents may not drive Scope", rule: .agentsOff)
        let json = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
        #expect(!json.contains("rule"))
        #expect(!json.contains("agents-off"))
    }
}
