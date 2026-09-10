import Foundation
import Network
import Synchronization

/// Client side of the one-message-per-connection protocol: connect, send, half-close, done.
///
/// This is what `scope-hook` does. A missing or dead socket fails fast (`.unreachable`) instead of waiting for
/// the path to come back, and everything is bounded by `timeout`.
public enum UnixSocketClient {
    /// Sends `payload` to the unix socket at `path` and returns once the server has taken it.
    /// - Throws: `UnixSocketError.payloadTooLarge`, `.unreachable`, `.timedOut`, or the underlying `NWError`.
    public static func send(_ payload: Data, to path: String, timeout: Duration = .seconds(2)) async throws {
        guard payload.count <= UnixSocketServer.maxMessageBytes else {
            throw UnixSocketError.payloadTooLarge(bytes: payload.count)
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: .unix(path: path), using: parameters)
        let queue = DispatchQueue(label: "dev.scope.sock.client")
        let outcome = Outcome()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { error in
                        if let error {
                            outcome.finish(continuation, throwing: error)
                        } else {
                            outcome.finish(continuation, throwing: nil)
                        }
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                    })
                case .failed(let error):
                    outcome.finish(continuation, throwing: UnixSocketError.unreachable(path: path, reason: error.localizedDescription))
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                case .waiting(let error):
                    // For a local unix socket "waiting" means nobody is listening; do not sit on it.
                    outcome.finish(continuation, throwing: UnixSocketError.unreachable(path: path, reason: error.localizedDescription))
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                case .cancelled:
                    outcome.finish(continuation, throwing: UnixSocketError.unreachable(path: path, reason: "cancelled"))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if outcome.finish(continuation, throwing: UnixSocketError.timedOut(path: path)) {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Sends a control frame and reads the whole reply (newline-separated JSON lines, ended by
    /// end-of-file).
    ///
    /// Unlike `send`, the connection is *not* half-closed after the request: the server answers on it. The
    /// frame is what tells the server this is a request and not a hook message (see `SocketFrame`).
    /// - Returns: the raw reply bytes; split them with `SocketFrame.lines`.
    public static func request(_ body: Data, to path: String, timeout: Duration = .seconds(30)) async throws -> Data {
        let payload = SocketFrame.encode(body)
        guard payload.count <= UnixSocketServer.maxMessageBytes else {
            throw UnixSocketError.payloadTooLarge(bytes: payload.count)
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: .unix(path: path), using: parameters)
        let queue = DispatchQueue(label: "dev.scope.sock.request")
        let outcome = ReplyOutcome()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, contentContext: .defaultMessage, isComplete: false,
                                    completion: .contentProcessed { error in
                        if let error {
                            outcome.finish(continuation, .failure(error))
                            connection.cancel()
                            return
                        }
                        // From here the receive loop owns the outcome: the server's close would otherwise
                        // reach the state handler as `.cancelled` and race the end-of-file we are waiting for.
                        connection.stateUpdateHandler = nil
                        receiveReply(connection, accumulated: Data(), outcome: outcome, continuation: continuation)
                    })
                case .failed(let error):
                    outcome.finish(continuation, .failure(UnixSocketError.unreachable(path: path, reason: error.localizedDescription)))
                    connection.cancel()
                case .waiting(let error):
                    // Nobody is listening on a local socket; do not sit on it (see `send`).
                    outcome.finish(continuation, .failure(UnixSocketError.unreachable(path: path, reason: error.localizedDescription)))
                    connection.cancel()
                case .cancelled:
                    outcome.finish(continuation, .failure(UnixSocketError.unreachable(path: path, reason: "cancelled")))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) {
                if outcome.finish(continuation, .failure(UnixSocketError.timedOut(path: path))) {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Accumulates reply bytes until the server closes its side.
    private static func receiveReply(_ connection: NWConnection, accumulated: Data, outcome: ReplyOutcome,
                                     continuation: CheckedContinuation<Data, any Error>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let error {
                outcome.finish(continuation, .failure(error))
                connection.cancel()
                return
            }
            if isComplete {
                outcome.finish(continuation, .success(buffer))
                connection.stateUpdateHandler = nil
                connection.cancel()
                return
            }
            receiveReply(connection, accumulated: buffer, outcome: outcome, continuation: continuation)
        }
    }

    /// `Outcome` for the request/response path, which resumes with the reply bytes.
    private final class ReplyOutcome: Sendable {
        private let resumed = Mutex(false)

        @discardableResult
        func finish(_ continuation: CheckedContinuation<Data, any Error>, _ result: Result<Data, any Error>) -> Bool {
            let first = resumed.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            guard first else { return false }
            continuation.resume(with: result)
            return true
        }
    }

    /// Guarantees the continuation is resumed exactly once whichever callback wins.
    private final class Outcome: Sendable {
        private let resumed = Mutex(false)

        /// Resumes the continuation if nobody did yet; returns `true` when this call was the one.
        @discardableResult
        func finish(_ continuation: CheckedContinuation<Void, any Error>, throwing error: (any Error)?) -> Bool {
            let first = resumed.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            guard first else { return false }
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
            return true
        }
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for Dispatch deadlines.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
