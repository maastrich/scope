import Foundation
import ScopeAdapters
import ScopeCore

/// Where a client looks for the running app.
public enum ControlEndpoint {
    /// `--sock`, then `SCOPE_SOCK` (Scope exports it into every thread), then the socket of `--home` /
    /// `SCOPE_HOME` / `~/.scope`.
    public static func resolve(socket: String? = nil, home: String? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let socket, !socket.isEmpty { return socket }
        if let fromEnvironment = environment["SCOPE_SOCK"], !fromEnvironment.isEmpty { return fromEnvironment }
        let homeURL: URL = if let home, !home.isEmpty {
            URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            ScopeHome.url(environment: environment)
        }
        return SocketPath.resolve(home: homeURL)
    }

    /// The line to add when nothing is listening. A Debug build keeps its own home and its own socket, and
    /// that is the mistake everyone makes first.
    public static func hint(for path: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let debugHome = ScopeHome.url(environment: environment.filter { $0.key != "SCOPE_HOME" }, folderName: ".scope-debug")
        let debugSocket = SocketPath.resolve(home: debugHome)
        guard debugSocket != path, FileManager.default.fileExists(atPath: debugSocket) else { return nil }
        return "A Debug build is listening on \(debugSocket). Use SCOPE_HOME=\(debugHome.path) to talk to it."
    }
}

/// The client half of the protocol: one call, one connection, one typed answer.
///
/// Used by the `scope` CLI and by `scope mcp`; both go through here so neither can grow logic of its own.
public struct ControlClient: Sendable {
    public let socketPath: String
    /// What the app records as the origin of what it does: `scope-cli/0.3.1`, `scope-mcp/0.3.1`.
    public let client: String
    /// Overrides `ControlCall.timeout` when set.
    public let timeout: Duration?

    public init(socketPath: String, client: String, timeout: Duration? = nil) {
        self.socketPath = socketPath
        self.client = client
        self.timeout = timeout
    }

    /// Sends `call` and waits for the result.
    /// - Parameter onPending: every `pending` line, as it arrives (the app asking the user, mostly).
    /// - Throws: `ControlError` — including for a socket that is not there, so a caller has one thing to catch.
    public func call(_ call: ControlCall,
                     caller: ControlCaller? = nil,
                     onPending: (@Sendable (String) -> Void)? = nil) async throws -> ControlResultPayload {
        let caller = caller ?? ControlCaller.fromEnvironment(ProcessInfo.processInfo.environment,
                                                             cwd: FileManager.default.currentDirectoryPath,
                                                             client: client)
        let request = ControlRequest(caller: caller, call: call)
        let body: Data
        do {
            body = try request.encoded()
        } catch {
            throw ControlError.badRequest("could not encode the request", detail: String(describing: error))
        }

        let reply: Data
        do {
            reply = try await UnixSocketClient.request(body, to: socketPath, timeout: timeout ?? call.timeout)
        } catch let error as UnixSocketError {
            throw ControlClient.socketError(error, path: socketPath)
        } catch {
            throw ControlError.failed("could not talk to Scope", detail: String(describing: error))
        }

        var last: ControlResponse?
        for line in SocketFrame.lines(reply) {
            guard let response = try? ControlResponse.decode(line, method: call.method) else { continue }
            if response.kind == .pending {
                if let message = response.message { onPending?(message) }
                continue
            }
            last = response
        }
        guard let last else {
            throw ControlError.failed("Scope closed the connection without answering")
        }
        if let error = last.error { throw error }
        guard let payload = last.payload else {
            throw ControlError.failed("Scope answered without a result")
        }
        return payload
    }

    /// Turns a transport failure into the error a user reads.
    static func socketError(_ error: UnixSocketError, path: String) -> ControlError {
        switch error {
        case .unreachable:
            var detail = "Nothing is listening on \(path). Is Scope running?"
            if let hint = ControlEndpoint.hint(for: path) { detail += "\n\(hint)" }
            return ControlError(.failed, "Scope is not reachable", detail: detail)
        case .timedOut:
            return ControlError(.timeout, "Scope did not answer in time",
                                detail: "Socket \(path) accepted the request and said nothing. A Scope older than "
                                    + "this `scope` binary listens there without understanding it — update the app.")
        case .pathTooLong, .payloadTooLarge:
            return ControlError(.badRequest, error.description)
        }
    }
}
