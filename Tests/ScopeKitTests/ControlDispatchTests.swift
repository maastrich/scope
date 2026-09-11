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
            return answer
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
}
