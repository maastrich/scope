import Foundation
import ScopeCore

/// What the app must provide for the socket to be able to answer. The whole app side of the CLI and of the
/// MCP server is this protocol and nothing else: both façades call the same methods.
@MainActor
public protocol ControlService: AnyObject {
    /// The automation rules in force (`config.json`).
    var automation: AutomationSettings { get }

    /// What agents keep open right now: tasks they created and nobody archived, threads they opened still running.
    var agentLoad: AutomationLoad { get }

    /// The budget held by allowed requests still being carried out; owned by the service, kept by the dispatch.
    var reservations: AutomationReservations { get }

    /// Turns what a caller claims about itself into what the app can vouch for.
    func origin(for caller: ControlCaller) -> ControlOrigin

    /// Asks the user to approve `subject`. `false` for a refusal *and* for a timeout: the caller cannot
    /// tell the difference and does not need to.
    func confirm(_ subject: String, from origin: ControlOrigin, caller: ControlCaller) async -> Bool

    /// Runs the call. Only reached once the policy allowed it (or the user did).
    func perform(_ call: ControlCall, from origin: ControlOrigin, caller: ControlCaller,
                 progress: @escaping @Sendable (String) -> Void) async -> Result<ControlResultPayload, ControlError>

    /// Called once per request the dispatch answered, refused ones included, with how it ended and how long it took.
    func finished(_ request: ControlRequest, from origin: ControlOrigin, outcome: ControlOutcome, seconds: TimeInterval)
}

extension ControlService {
    public func finished(_ request: ControlRequest, from origin: ControlOrigin, outcome: ControlOutcome, seconds: TimeInterval) {}
}

/// How a control request ended, in words the event journal keeps: never the message, which names tasks and threads.
public struct ControlOutcome: Sendable, Equatable {
    public enum Status: String, Sendable {
        case ok, refused, error
    }

    public var status: Status
    /// The refusal rule (`ControlError.Rule`) or the error code; `nil` when it went through.
    public var cause: String?

    public init(status: Status, cause: String? = nil) {
        self.status = status
        self.cause = cause
    }

    public static let ok = ControlOutcome(status: .ok)

    public init(_ result: Result<ControlResultPayload, ControlError>) {
        switch result {
        case .success: self = .ok
        case .failure(let error): self.init(error)
        }
    }

    public init(_ error: ControlError) {
        if error.code == .denied {
            self.init(status: .refused, cause: (error.rule ?? .other).rawValue)
        } else {
            self.init(status: .error, cause: error.code.rawValue)
        }
    }
}

/// Holds the service between the socket server (built first, in the composition root) and the app model
/// (built after). Same trick as `HookSink`.
@MainActor
public final class ControlSink {
    public var service: (any ControlService)?

    public init(service: (any ControlService)? = nil) {
        self.service = service
    }
}

/// Decode → policy → service → response. The one path every control request takes, testable without a
/// socket and without an app: hand it a service double.
public enum ControlDispatch {
    /// Runs one already-decoded request.
    @MainActor
    public static func run(_ request: ControlRequest, service: any ControlService,
                           progress: @escaping @Sendable (String) -> Void) async -> ControlResponse {
        let origin = service.origin(for: request.caller)
        let started = ContinuousClock.now
        let response = await dispatch(request, service: service, origin: origin, progress: progress)
        let outcome = response.error.map(ControlOutcome.init) ?? .ok
        let (whole, attoseconds) = (ContinuousClock.now - started).components
        service.finished(request, from: origin, outcome: outcome, seconds: TimeInterval(whole) + TimeInterval(attoseconds) / 1e18)
        return response
    }

    @MainActor
    private static func dispatch(_ request: ControlRequest, service: any ControlService, origin: ControlOrigin,
                                 progress: @escaping @Sendable (String) -> Void) async -> ControlResponse {
        let policy = AutomationPolicy(settings: service.automation)
        let load = { service.agentLoad + service.reservations.pending }
        switch policy.decide(request.call, from: origin, load: load()) {
        case .refuse(let error):
            Log.hooks.info("control \(request.method.rawValue, privacy: .public) refused: \(error.message, privacy: .public)")
            return .failure(id: request.id, error)
        case .ask(let subject):
            progress("waiting for you to approve: \(subject)")
            guard await service.confirm(subject, from: origin, caller: request.caller) else {
                // A refusal, no answer before the timeout, or too many questions already waiting: the caller
                // cannot tell which, so the answer must not claim the user said no.
                return .failure(id: request.id, .denied(
                    "the user did not approve this request to \(subject)",
                    detail: "Refused, left unanswered past the approval timeout, or turned away because several "
                        + "questions were already waiting. Do not ask again right away.", rule: .notApproved))
            }
            // Other requests may have been carried out while the user read the question.
            if let refusal = policy.budgetRefusal(request.call, from: origin, load: load()) {
                return .failure(id: request.id, refusal)
            }
        case .allow:
            break
        }
        // No suspension between the last check and the reservation: two requests cannot both take the last slot.
        let reserved = origin.isAgent ? AutomationPolicy.cost(of: request.call) : .zero
        service.reservations.reserve(reserved)
        defer { service.reservations.release(reserved) }
        switch await service.perform(request.call, from: origin, caller: request.caller, progress: progress) {
        case .success(let payload):
            return .result(id: request.id, payload)
        case .failure(let error):
            return .failure(id: request.id, error)
        }
    }

    /// Runs an already-decoded request, service or not. `"0"` stands in for the id of a request that was
    /// too broken to carry one.
    @MainActor
    public static func run(_ decoded: Result<ControlRequest, ControlRequest.Failure>,
                           service: (any ControlService)?,
                           progress: @escaping @Sendable (String) -> Void) async -> ControlResponse {
        switch decoded {
        case .failure(let failure):
            return .failure(id: failure.id ?? "0", failure.error)
        case .success(let request):
            guard let service else {
                return .failure(id: request.id, .init(.failed, "Scope is still starting up"))
            }
            return await run(request, service: service, progress: progress)
        }
    }

    /// The id to answer on, whether or not the request decoded.
    public static func id(of decoded: Result<ControlRequest, ControlRequest.Failure>) -> String {
        switch decoded {
        case .success(let request): request.id
        case .failure(let failure): failure.id ?? "0"
        }
    }
}
