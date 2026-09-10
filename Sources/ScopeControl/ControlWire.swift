import Foundation
import ScopeAdapters
import ScopeCore

/// One request on the wire.
///
/// Decoding happens in two passes on purpose: the envelope first (`rpc`, `id`, `method`), the parameters
/// after. An unknown method or a future protocol version can then be refused *with the request's id*, which
/// is what lets an old `scope` binary print a real error instead of hanging on a reply it cannot match.
public struct ControlRequest: Sendable, Equatable {
    public var rpc: Int
    /// Correlation id, echoed in every reply line. 8 hex characters is plenty for one connection.
    public var id: String
    public var caller: ControlCaller
    public var call: ControlCall

    public init(id: String = ControlRequest.newID(), caller: ControlCaller, call: ControlCall,
                rpc: Int = ControlProtocol.version) {
        self.rpc = rpc
        self.id = id
        self.caller = caller
        self.call = call
    }

    public var method: ControlMethod { call.method }

    /// A fresh correlation id.
    public static func newID() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    /// One line of JSON, ready to be framed by `SocketFrame.encode`.
    public func encoded() throws -> Data {
        let encoder = ControlProtocol.makeEncoder()
        func wire<P: Encodable>(_ params: P?) -> Wire<P> {
            Wire(rpc: rpc, id: id, method: method.rawValue, caller: caller, params: params)
        }
        return switch call {
        case .ping: try encoder.encode(wire(Empty?.none))
        case .list(let params): try encoder.encode(wire(params))
        case .threadNew(let params): try encoder.encode(wire(params))
        case .taskNew(let params): try encoder.encode(wire(params))
        }
    }

    /// Decodes a request body. Every refusal carries the id when the envelope was readable, so the server
    /// can answer instead of dropping the connection.
    public static func decode(_ data: Data) -> Result<ControlRequest, Failure> {
        let decoder = ControlProtocol.makeDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return .failure(Failure(id: nil, error: .badRequest("unreadable request")))
        }
        guard envelope.rpc <= ControlProtocol.version else {
            return .failure(Failure(id: envelope.id, error: .init(.unsupported,
                "this Scope speaks protocol \(ControlProtocol.version), the request asks for \(envelope.rpc)",
                detail: "Update Scope, or use the `scope` binary that ships with it.")))
        }
        guard let method = ControlMethod(rawValue: envelope.method) else {
            return .failure(Failure(id: envelope.id, error: .init(.unsupported, "unknown method “\(envelope.method)”",
                detail: "This Scope knows: " + ControlMethod.allCases.map(\.rawValue).joined(separator: ", "))))
        }
        let caller = envelope.caller ?? ControlCaller(client: "unknown")
        do {
            let call: ControlCall = switch method {
            case .ping: .ping
            case .list: .list(try decoder.decode(Params<ListParams>.self, from: data).params ?? ListParams())
            case .threadNew: .threadNew(try decoder.decode(Params<ThreadNewParams>.self, from: data).params ?? ThreadNewParams())
            case .taskNew: .taskNew(try decoder.decode(Params<TaskNewParams>.self, from: data).params
                ?? { throw ControlError.badRequest("task.new needs a prompt") }())
            }
            return .success(ControlRequest(id: envelope.id, caller: caller, call: call, rpc: envelope.rpc))
        } catch let error as ControlError {
            return .failure(Failure(id: envelope.id, error: error))
        } catch {
            return .failure(Failure(id: envelope.id,
                                    error: .badRequest("unusable parameters for \(method.rawValue)",
                                                       detail: String(describing: error))))
        }
    }

    /// A request that could not be turned into a call, with the id to answer on when there was one.
    public struct Failure: Sendable, Equatable, Error {
        public var id: String?
        public var error: ControlError
    }

    /// Encoding shape: the envelope with typed parameters.
    private struct Wire<P: Encodable>: Encodable {
        var rpc: Int
        var id: String
        var method: String
        var caller: ControlCaller
        var params: P?
    }

    private struct Envelope: Decodable {
        var rpc: Int
        var id: String
        var method: String
        var caller: ControlCaller?
    }

    private struct Params<T: Decodable>: Decodable {
        var params: T?
    }
}

/// One reply line. A call answers with zero or more `pending` lines and exactly one `result`.
public struct ControlResponse: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Still working, here is why — shown by the CLI, forwarded as MCP progress.
        case pending
        /// The last line of the exchange.
        case result
    }

    public var rpc: Int
    public var id: String
    public var kind: Kind
    /// `pending` only: what the app is waiting for.
    public var message: String?
    public var payload: ControlResultPayload?
    public var error: ControlError?

    public static func pending(id: String, message: String) -> ControlResponse {
        ControlResponse(rpc: ControlProtocol.version, id: id, kind: .pending, message: message)
    }

    public static func result(id: String, _ payload: ControlResultPayload) -> ControlResponse {
        ControlResponse(rpc: ControlProtocol.version, id: id, kind: .result, payload: payload)
    }

    public static func failure(id: String, _ error: ControlError) -> ControlResponse {
        ControlResponse(rpc: ControlProtocol.version, id: id, kind: .result, error: error)
    }

    /// `true` when the exchange ended well.
    public var ok: Bool { kind == .result && error == nil }

    /// One line of JSON, without the trailing newline (`SocketResponder` adds it).
    public func encoded() throws -> Data {
        let encoder = ControlProtocol.makeEncoder()
        func wire<R: Encodable>(_ result: R?) -> Wire<R> {
            Wire(rpc: rpc, id: id, kind: kind.rawValue, message: message,
                 ok: kind == .result ? ok : nil, result: result, error: error)
        }
        return switch payload {
        case nil: try encoder.encode(wire(Empty?.none))
        case .ping(let result): try encoder.encode(wire(result))
        case .list(let result): try encoder.encode(wire(result))
        case .thread(let result): try encoder.encode(wire(result))
        case .task(let result): try encoder.encode(wire(result))
        }
    }

    /// Decodes one reply line. The method is what says how to read `result`, so the client passes the one
    /// it asked for.
    public static func decode(_ data: Data, method: ControlMethod) throws -> ControlResponse {
        let decoder = ControlProtocol.makeDecoder()
        let line = try decoder.decode(Line.self, from: data)
        guard let kind = Kind(rawValue: line.kind) else {
            // A future app may invent line kinds; anything that is not a result is progress noise.
            return ControlResponse(rpc: line.rpc, id: line.id, kind: .pending, message: line.message)
        }
        var payload: ControlResultPayload?
        if line.result != nil {
            payload = switch method {
            case .ping: .ping(try decoder.decode(Wrapped<PingResult>.self, from: data).result)
            case .list: .list(try decoder.decode(Wrapped<ListResult>.self, from: data).result)
            case .threadNew: .thread(try decoder.decode(Wrapped<ThreadNewResult>.self, from: data).result)
            case .taskNew: .task(try decoder.decode(Wrapped<TaskNewResult>.self, from: data).result)
            }
        }
        return ControlResponse(rpc: line.rpc, id: line.id, kind: kind, message: line.message,
                               payload: payload, error: line.error)
    }

    /// Encoding shape: the reply line with a typed result.
    private struct Wire<R: Encodable>: Encodable {
        var rpc: Int
        var id: String
        var kind: String
        var message: String?
        var ok: Bool?
        var result: R?
        var error: ControlError?
    }

    private struct Line: Decodable {
        var rpc: Int
        var id: String
        var kind: String
        var message: String?
        var error: ControlError?
        /// Only its presence matters here; the typed decode happens in a second pass.
        var result: Presence?

        struct Presence: Decodable {
            init(from decoder: any Decoder) throws {}
        }
    }

    private struct Wrapped<T: Decodable>: Decodable {
        var result: T
    }
}

/// Stands in for "this call has no parameters / no result" so the generic wire shapes stay one type.
struct Empty: Codable, Sendable, Equatable {}
