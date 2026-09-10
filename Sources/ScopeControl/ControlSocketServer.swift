import Foundation
import ScopeAdapters
import ScopeCore

/// The app's single listener: hook messages *and* control requests, one socket, one file at 0600.
///
/// Hook messages keep the path they always had (`HookSocketServer.accept`, then the main-actor sink).
/// Control requests are decoded, run through `ControlDispatch` and answered on the same connection.
///
/// A request that nobody answers would hold a connection open forever — a handler bug, or a confirmation
/// sheet the user walked away from — so every exchange carries a deadline and ends in a `timeout` reply.
public final class ControlSocketServer: Sendable {
    /// The socket file (exported as `SCOPE_SOCK` into every thread).
    public nonisolated let path: String
    /// How long a single request may take before it is answered with `timeout`.
    public let timeout: Duration

    private let server: UnixSocketServer
    private let queue = DispatchQueue(label: "dev.scope.control.deadline", qos: .userInitiated)

    /// - Parameters:
    ///   - path: socket file path (see `SocketPath.resolve`).
    ///   - isKnownThread: synchronous check run on the socket queue (`KnownThreads.contains`).
    ///   - hookSink: receives every accepted hook event on the main actor.
    ///   - controls: holds the app's `ControlService`, which only exists once the model is built.
    ///   - timeout: deadline for one control exchange.
    ///   - onFailure: called when the listener fails after `start()`.
    public init(path: String,
                isKnownThread: @escaping @Sendable (ThreadID) -> Bool,
                hookSink: @escaping @MainActor @Sendable (AdapterEvent) -> Void,
                controls: ControlSink,
                timeout: Duration = .seconds(180),
                onFailure: (@Sendable (any Error) -> Void)? = nil) throws {
        self.path = path
        self.timeout = timeout
        let deadlineQueue = queue
        self.server = try UnixSocketServer(
            path: path,
            onMessage: { data in
                guard let event = HookSocketServer.accept(data, isKnownThread: isKnownThread) else { return }
                Task { @MainActor in hookSink(event) }
            },
            onRequest: { body, responder in
                // The id is lifted before anything else so a timeout or a progress line still correlates.
                let decoded = ControlRequest.decode(body)
                let id = ControlDispatch.id(of: decoded)
                deadlineQueue.asyncAfter(deadline: .now() + timeout.seconds) {
                    let late = ControlResponse.failure(id: id, .init(.timeout, "Scope did not answer in time"))
                    responder.finish(try? late.encoded())
                }
                Task { @MainActor in
                    let response = await ControlDispatch.run(decoded, service: controls.service, progress: { message in
                        guard let line = try? ControlResponse.pending(id: id, message: message).encoded() else { return }
                        responder.send(line)
                    })
                    responder.finish(try? response.encoded())
                }
            },
            onFailure: onFailure
        )
    }

    /// Starts listening.
    public func start() {
        server.start()
    }

    /// Stops listening and removes the socket file.
    public func stop() {
        server.stop()
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for Dispatch deadlines.
    var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }
}
