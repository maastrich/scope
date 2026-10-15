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
        let policy = AutomationPolicy(settings: service.automation)
        let load = { service.agentLoad + service.reservations.pending }
        switch policy.decide(request.call, from: origin, load: load()) {
        case .refuse(let error):
            Log.hooks.info("control \(request.method.rawValue, privacy: .public) refused: \(error.message, privacy: .public)")
            return .failure(id: request.id, error)
        case .ask(let subject):
            progress("waiting for you to approve: \(subject)")
            guard await service.confirm(subject, from: origin, caller: request.caller) else {
                return .failure(id: request.id, .denied("you did not approve \(subject)"))
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
