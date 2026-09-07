import Foundation
import Network
import ScopeCore

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
/// One message per connection: a client connects, writes its payload, half-closes, and the whole payload is
/// handed to `onMessage` on the server's own dispatch queue (never on the main thread). Nothing is written
/// back. Verified on macOS 15 with both an `NWConnection` client and a plain `nc -U` client.
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
            Self.receiveAll(connection, accumulated: Data(), onMessage: onMessage)
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
                                   onMessage: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > maxMessageBytes {
                Log.hooks.warning("dropping oversized socket message (\(buffer.count) bytes)")
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                if !buffer.isEmpty { onMessage(buffer) }
                connection.cancel()
            } else {
                receiveAll(connection, accumulated: buffer, onMessage: onMessage)
            }
        }
    }
}
