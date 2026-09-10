import Foundation
import Network
import ScopeCore
import Synchronization

/// Errors raised by the unix socket server and client.
public enum UnixSocketError: Error, Sendable, Equatable {
    /// The path does not fit in `sockaddr_un.sun_path` (see `SocketPath.maxLength`).
    case pathTooLong(String)
    /// The client did not get its payload through within the timeout.
    case timedOut(path: String)
    /// The client could not reach the socket (no server listening, permission denied, …).
    case unreachable(path: String, reason: String)
    /// The client was asked to send more than the server accepts.
    case payloadTooLarge(bytes: Int)
}

extension UnixSocketError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .pathTooLong(let path):
            "socket path is longer than \(SocketPath.maxLength) bytes: \(path)"
        case .timedOut(let path):
            "timed out sending to \(path)"
        case .unreachable(let path, let reason):
            "socket unreachable at \(path) (\(reason))"
        case .payloadTooLarge(let bytes):
            "payload of \(bytes) bytes exceeds the \(UnixSocketServer.maxMessageBytes)-byte limit"
        }
    }

    public var errorDescription: String? { description }
}

/// Unix-domain stream socket server on Network.framework.
///
/// Two shapes share the socket, told apart by `SocketFrame`.
///
/// A *hook message* is one payload per connection: the client connects, writes, half-closes, and the whole
/// payload reaches `onMessage` on the server's own dispatch queue (never on the main thread). Nothing is
/// written back. Verified on macOS 15 with both an `NWConnection` client and a plain `nc -U` client.
///
/// A *control frame* (`scope-rpc/1\n<json>\n`) reaches `onRequest` together with a `SocketResponder`: the
/// client is still holding the connection open, waiting for reply lines and then end-of-file. Without an
/// `onRequest` handler the server behaves exactly as it did before frames existed.
public final class UnixSocketServer: Sendable {
    /// Largest message accepted from one connection; anything bigger is dropped with a log line.
    public static let maxMessageBytes = 1 << 20

    /// The socket file this server binds to.
    public let path: String

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.scope.sock.server")

    /// Creates the server (does not listen yet; call `start()`).
    ///
    /// A stale socket file left by a previous run is unlinked first, otherwise `bind` fails with
    /// `EADDRINUSE`. Once listening, the socket file is chmod'ed to `0600` so only the current user can
    /// connect (connecting to a unix socket needs write permission on the file).
    /// - Parameters:
    ///   - path: socket file path, at most `SocketPath.maxLength` bytes.
    ///   - onMessage: receives every complete client payload.
    ///   - onFailure: called when the listener fails after `start()` (bind error, …). The app reports it as
    ///     a Problem and keeps running without adapters.
    public init(path: String, onMessage: @escaping @Sendable (Data) -> Void,
                onRequest: (@Sendable (Data, SocketResponder) -> Void)? = nil,
                onFailure: (@Sendable (any Error) -> Void)? = nil) throws {
        guard SocketPath.fits(path) else { throw UnixSocketError.pathTooLong(path) }
        self.path = path
        unlink(path)

        // "tcp" only means stream semantics here; Network.framework ignores it for AF_UNIX.
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveAll(connection, accumulated: Data(), onMessage: onMessage, onRequest: onRequest)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                chmod(path, 0o600)
                Log.hooks.info("listening on \(path, privacy: .public)")
            case .failed(let error):
                Log.hooks.error("listener failed on \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                onFailure?(error)
            case .cancelled:
                Log.hooks.debug("listener cancelled on \(path, privacy: .public)")
            default:
                break
            }
        }
    }

    /// Starts listening. Failures are asynchronous and reach `onFailure`.
    public func start() {
        listener.start(queue: queue)
    }

    /// Stops listening and removes the socket file. Safe to call more than once.
    public func stop() {
        listener.cancel()
        unlink(path)
    }

    private static func receiveAll(_ connection: NWConnection, accumulated: Data,
                                   onMessage: @escaping @Sendable (Data) -> Void,
                                   onRequest: (@Sendable (Data, SocketResponder) -> Void)?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > maxMessageBytes {
                Log.hooks.warning("dropping oversized socket message (\(buffer.count) bytes)")
                connection.cancel()
                return
            }
            if let onRequest {
                switch SocketFrame.classify(buffer) {
                case .frame(let version, let body):
                    // One request per connection: the responder owns the connection from here.
                    guard version == SocketFrame.version else {
                        Log.hooks.warning("dropping control frame of unknown framing version \(version)")
                        connection.cancel()
                        return
                    }
                    onRequest(body, SocketResponder(connection))
                    return
                case .malformed(let reason):
                    Log.hooks.warning("dropping malformed control frame: \(reason, privacy: .public)")
                    connection.cancel()
                    return
                case .incomplete, .hookMessage:
                    break
                }
            }
            if isComplete || error != nil {
                if !buffer.isEmpty { onMessage(buffer) }
                connection.cancel()
            } else {
                receiveAll(connection, accumulated: buffer, onMessage: onMessage, onRequest: onRequest)
            }
        }
    }
}

/// The write side of one control connection: reply lines, then end-of-file.
///
/// Handed to the server's `onRequest` on the socket queue; the handler usually hops to the main actor and
/// answers later, so every method is safe from any thread and `close()` is idempotent. The connection is
/// only cancelled from inside a send completion — cancelling straight after `send` can drop bytes that
/// have not reached the kernel yet.
public final class SocketResponder: Sendable {
    private let connection: NWConnection
    private let closed = Mutex(false)

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Writes one reply line (a newline is appended). No-op once closed.
    public func send(_ line: Data) {
        guard !closed.withLock({ $0 }) else { return }
        var payload = line
        payload.append(0x0A)
        write(payload, final: false, then: nil)
    }

    /// Writes a last line and closes; the client sees end-of-file. Idempotent.
    public func finish(_ line: Data? = nil) {
        let first = closed.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard first else { return }
        let connection = connection
        let close = { @Sendable in
            // Only cancel once the kernel has the bytes: cancelling straight after `send` drops them.
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
        guard var payload = line else {
            close()
            return
        }
        payload.append(0x0A)
        write(payload, final: false, then: close)
    }

    private func write(_ payload: Data, final: Bool, then next: (@Sendable () -> Void)?) {
        connection.send(content: payload, contentContext: final ? .finalMessage : .defaultMessage, isComplete: true,
                        completion: .contentProcessed { error in
            if let error {
                Log.hooks.warning("control reply failed: \(error.localizedDescription, privacy: .public)")
            }
            next?()
        })
    }
}
