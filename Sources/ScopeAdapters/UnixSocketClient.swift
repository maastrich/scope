import Foundation
import Network
import Synchronization

/// Client side of the one-message-per-connection protocol: connect, send, half-close, wait for the server to close.
///
/// This is what `scope-hook` does. A missing or dead socket fails fast (`.unreachable`) instead of waiting for
/// the path to come back, and everything is bounded by `timeout`.
public enum UnixSocketClient {
    /// Sends `payload` to the unix socket at `path` and returns once the server has read it and closed the
    /// connection.
    ///
    /// Returning as soon as the bytes are buffered is not enough: `NWListener` silently drops a connection whose
    /// client has closed before it was accepted, so a hook that hung up at once lost its event whenever the app was
    /// slow to accept. The server closes only once it has read the message; that close is the receipt. Plain BSD
    /// sockets rather than `NWConnection`, which on a loaded machine reports a local socket as "Network is down"
    /// and leaves no way to tell a receipt from a failure.
    /// - Throws: `UnixSocketError.payloadTooLarge`, `.pathTooLong`, `.unreachable`, `.timedOut`.
    public static func send(_ payload: Data, to path: String, timeout: Duration = .seconds(2)) async throws {
        guard payload.count <= UnixSocketServer.maxMessageBytes else {
            throw UnixSocketError.payloadTooLarge(bytes: payload.count)
        }
        let deadline = Date.now.addingTimeInterval(timeout.timeInterval)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try deliver(payload, to: path, deadline: deadline) })
            }
        }
    }

    /// The blocking part of `send`, on a non-blocking descriptor polled up to `deadline`.
    private static func deliver(_ payload: Data, to path: String, deadline: Date) throws {
        guard SocketPath.fits(path) else { throw UnixSocketError.pathTooLong(path) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw unreachable(path, errno) }
        defer { close(descriptor) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        while true {
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 || errno == EISCONN { break }
            // A full backlog or a connect under way: the listener is there, just behind. Anything else means nobody is.
            guard [EAGAIN, EINTR, EINPROGRESS, EALREADY].contains(errno) else { throw unreachable(path, errno) }
            try wait(descriptor, for: Int16(POLLOUT), until: deadline, path: path)
        }

        try payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 { offset += written; continue }
                guard written < 0, errno == EAGAIN || errno == EINTR else { throw unreachable(path, errno) }
                try wait(descriptor, for: Int16(POLLOUT), until: deadline, path: path)
            }
        }
        shutdown(descriptor, SHUT_WR)

        // The server writes nothing on this path: the end of file (or a reset, the same close seen late) is the receipt.
        var byte: UInt8 = 0
        while true {
            let count = read(descriptor, &byte, 1)
            if count >= 0 || errno == ECONNRESET { return }
            guard errno == EAGAIN || errno == EINTR else { throw unreachable(path, errno) }
            try wait(descriptor, for: Int16(POLLIN), until: deadline, path: path)
        }
    }

    private static func wait(_ descriptor: Int32, for events: Int16, until deadline: Date, path: String) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw UnixSocketError.timedOut(path: path) }
        var entry = pollfd(fd: descriptor, events: events, revents: 0)
        // A full backlog does not wake `poll` when it drains: look again every few milliseconds.
        let slice = events == Int16(POLLOUT) ? min(remaining, 0.01) : remaining
        _ = poll(&entry, 1, Int32((slice * 1000).rounded(.up)))
    }

    private static func unreachable(_ path: String, _ code: Int32) -> UnixSocketError {
        .unreachable(path: path, reason: String(cString: strerror(code)))
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
        let queue = DispatchQueue(label: "dev.scope.sock.request", qos: .userInitiated)
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
}

extension Duration {
    /// Seconds as a `TimeInterval`, for Dispatch deadlines.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
