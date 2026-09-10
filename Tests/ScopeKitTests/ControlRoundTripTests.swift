import Foundation
import ScopeCore
import Synchronization
import Testing
@testable import ScopeAdapters

/// The request/response half of the socket: a framed request is answered on the same connection while a
/// plain hook message still travels one way.
@Suite struct ControlRoundTripTests {
    static func temporarySocketPath() -> String {
        let name = "scope-ctl-\(UUID().uuidString.prefix(8).lowercased()).sock"
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name).path
    }

    /// `NWListener.start` is asynchronous: retry the first request until the server is really listening.
    static func requestRetrying(_ body: Data, to path: String, attempts: Int = 100) async throws -> Data {
        var lastError: (any Error)?
        for _ in 0..<attempts {
            do {
                return try await UnixSocketClient.request(body, to: path, timeout: .seconds(5))
            } catch let error as UnixSocketError {
                lastError = error
                guard case .unreachable = error else { throw error }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw lastError ?? UnixSocketError.unreachable(path: path, reason: "no attempts")
    }

    @Test func aFramedRequestIsAnsweredOnTheSameConnection() async throws {
        let path = Self.temporarySocketPath()
        let server = try UnixSocketServer(path: path, onMessage: { _ in }, onRequest: { body, responder in
            let text = String(decoding: body, as: UTF8.self)
            responder.finish(Data("echo:\(text)".utf8))
        })
        server.start()
        defer { server.stop() }

        let reply = try await Self.requestRetrying(Data(#"{"method":"ping"}"#.utf8), to: path)
        #expect(String(decoding: reply, as: UTF8.self) == "echo:{\"method\":\"ping\"}\n")
    }

    /// The reply can arrive long after the handler was called, from another thread — what the app does when
    /// it hops to the main actor to answer.
    @Test func aReplySentLaterStillReachesTheClient() async throws {
        let path = Self.temporarySocketPath()
        let server = try UnixSocketServer(path: path, onMessage: { _ in }, onRequest: { _, responder in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                responder.send(Data(#"{"kind":"pending"}"#.utf8))
                responder.finish(Data(#"{"kind":"result"}"#.utf8))
            }
        })
        server.start()
        defer { server.stop() }

        let reply = try await Self.requestRetrying(Data(#"{"method":"ping"}"#.utf8), to: path)
        let lines = SocketFrame.lines(reply).map { String(decoding: $0, as: UTF8.self) }
        #expect(lines == [#"{"kind":"pending"}"#, #"{"kind":"result"}"#])
    }

    /// A pretty-printed hook message — the shape `JSONStore` writes — still reaches `onMessage` whole.
    @Test func aHookMessageIsUntouchedByFraming() async throws {
        let path = Self.temporarySocketPath()
        let inbox = Mutex<[String]>([])
        let server = try UnixSocketServer(path: path, onMessage: { data in
            inbox.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
        }, onRequest: { _, responder in
            responder.finish(Data("unexpected".utf8))
        })
        server.start()
        defer { server.stop() }

        // The wire date keeps milliseconds only, so compare against what a round trip can preserve.
        let event = HookEvent(thread: "3f9a2c17be04", event: .turnStarted,
                              sentAt: Date(timeIntervalSince1970: 1_775_000_000.25))
        let payload = try event.encoded()
        #expect(String(decoding: payload, as: UTF8.self).contains("\n"))   // pretty-printed: newlines inside
        for _ in 0..<100 {
            do {
                try await UnixSocketClient.send(payload, to: path, timeout: .seconds(2))
                break
            } catch { try await Task.sleep(for: .milliseconds(20)) }
        }

        let deadline = ContinuousClock.now + .seconds(3)
        while inbox.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let received = inbox.withLock { $0 }
        #expect(received.count == 1)
        #expect(received.first.map { try? HookEvent.decode(Data($0.utf8)) } == event)
    }

    @Test func classificationTellsTheTwoShapesApart() {
        #expect(SocketFrame.classify(Data("{".utf8)) == .hookMessage)
        #expect(SocketFrame.classify(Data("sco".utf8)) == .incomplete)
        #expect(SocketFrame.classify(Data("scope-rpc/1\n".utf8)) == .incomplete)
        #expect(SocketFrame.classify(Data("scope-rpc/1\n{}\n".utf8)) == .frame(version: 1, body: Data("{}".utf8)))
        #expect(SocketFrame.classify(Data("scope-rpc/x\n{}\n".utf8)) == .malformed("unreadable header “scope-rpc/x”"))
        #expect(SocketFrame.classify(Data(repeating: UInt8(ascii: "s"), count: 64)) == .hookMessage)
    }
}
