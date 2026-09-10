import Foundation
import ScopeAdapters
import ScopeCore
import Testing
@testable import ScopeControl

/// The wire: what a client writes, what the app reads back, and what happens when the two builds disagree.
@Suite struct ControlProtocolTests {
    static let caller = ControlCaller(thread: "3f9a2c17be04", task: nil, cwd: "/tmp/work", client: "scope-cli/test")

    @Test func aRequestRoundTrips() throws {
        let request = ControlRequest(id: "abcd1234", caller: Self.caller,
                                     call: .threadNew(ThreadNewParams(scope: "acme", driver: "claude-code",
                                                                      title: "look at CI", prompt: "why is it red?")))
        let decoded = ControlRequest.decode(try request.encoded())
        #expect(try decoded.get() == request)
    }

    @Test func aRequestIsOneLineOfJSON() throws {
        let request = ControlRequest(caller: Self.caller, call: .taskNew(TaskNewParams(prompt: "fix the flaky login test\nsecond line")))
        let encoded = try request.encoded()
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\n"))
        // …and survives being framed and split again, which is what the socket does.
        let framed = SocketFrame.encode(encoded)
        #expect(SocketFrame.classify(framed) == .frame(version: 1, body: encoded))
    }

    @Test func callsWithoutParametersDecodeToTheirDefaults() throws {
        let body = Data(#"{"caller":{"client":"x"},"id":"7","method":"list","rpc":1}"#.utf8)
        let request = try ControlRequest.decode(body).get()
        #expect(request.call == .list(ListParams()))
    }

    @Test func anUnknownMethodIsUnsupportedAndKeepsTheID() {
        let body = Data(#"{"caller":{"client":"x"},"id":"7f2a","method":"thread.teleport","rpc":1}"#.utf8)
        guard case .failure(let failure) = ControlRequest.decode(body) else {
            Issue.record("a method from the future should not decode")
            return
        }
        #expect(failure.id == "7f2a")
        #expect(failure.error.code == .unsupported)
    }

    @Test func aNewerProtocolIsRefusedRatherThanGuessed() {
        let body = Data(#"{"caller":{"client":"x"},"id":"7f2a","method":"list","rpc":99}"#.utf8)
        guard case .failure(let failure) = ControlRequest.decode(body) else {
            Issue.record("a protocol from the future should not decode")
            return
        }
        #expect(failure.error.code == .unsupported)
    }

    @Test func rubbishIsRefusedWithoutAnID() {
        guard case .failure(let failure) = ControlRequest.decode(Data("not json".utf8)) else {
            Issue.record("that is not a request")
            return
        }
        #expect(failure.id == nil)
        #expect(failure.error.code == .badRequest)
    }

    @Test func aResultRoundTripsForItsOwnMethod() throws {
        let result = ThreadNewResult(thread: "3f9a2c17be04", title: "acme", driver: "shell", scope: "Acme",
                                     scopeSlug: "acme", cwd: "/tmp/acme", task: nil, depth: 1)
        let response = ControlResponse.result(id: "abcd", .thread(result))
        let decoded = try ControlResponse.decode(try response.encoded(), method: .threadNew)
        #expect(decoded.ok)
        #expect(decoded.payload == .thread(result))
    }

    @Test func aFailureCarriesItsCodeAndDetail() throws {
        let response = ControlResponse.failure(id: "abcd", .denied("no", detail: "because"))
        let decoded = try ControlResponse.decode(try response.encoded(), method: .taskNew)
        #expect(!decoded.ok)
        #expect(decoded.error == ControlError.denied("no", detail: "because"))
        #expect(decoded.payload == nil)
    }

    @Test func anUnknownErrorCodeStillReads() throws {
        let line = Data(#"{"error":{"code":"cosmic_ray","message":"oh"},"id":"1","kind":"result","ok":false,"rpc":1}"#.utf8)
        let decoded = try ControlResponse.decode(line, method: .ping)
        #expect(decoded.error?.code == .failed)
        #expect(decoded.error?.message == "oh")
    }

    @Test func pendingLinesAreNotResults() throws {
        let pending = ControlResponse.pending(id: "abcd", message: "waiting for you")
        let decoded = try ControlResponse.decode(try pending.encoded(), method: .taskNew)
        #expect(decoded.kind == .pending)
        #expect(decoded.message == "waiting for you")
        #expect(!decoded.ok)
    }

    @Test func theCallerIsReadFromTheEnvironment() {
        let caller = ControlCaller.fromEnvironment(
            ["SCOPE_THREAD": "3f9a2c17be04", "SCOPE_TASK": "/tmp/sandbox", "HOME": "/Users/x"],
            cwd: "/tmp/work", client: "scope-cli/1"
        )
        #expect(caller.thread == "3f9a2c17be04")
        #expect(caller.task == "/tmp/sandbox")
        #expect(caller.cwd == "/tmp/work")
    }

    @Test func anEmptyThreadVariableIsNoThread() {
        let caller = ControlCaller.fromEnvironment(["SCOPE_THREAD": ""], cwd: nil, client: "scope-cli/1")
        #expect(caller.thread == nil)
    }

    @Test func readsAreBoundedFarShorterThanWrites() {
        #expect(ControlCall.ping.timeout < ControlCall.threadNew(ThreadNewParams()).timeout)
        #expect(ControlCall.list(ListParams()).timeout < ControlCall.taskNew(TaskNewParams(prompt: "x")).timeout)
    }
}
