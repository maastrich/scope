import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

@Suite struct HookEventTests {
    @Test func roundTripKeepsEveryField() throws {
        let sentAt = Date(timeIntervalSince1970: 1_788_000_062.771)
        let original = HookEvent(thread: "3f9a2c17be04", event: .inputRequested,
                                 payload: ["reason": "permission", "tool": "Bash"],
                                 sentAt: sentAt, raw: #"{"session_id":"abc","hook_event_name":"Notification"}"#)
        let data = try original.encoded()
        let decoded = try HookEvent.decode(data)

        #expect(decoded.thread == original.thread)
        #expect(decoded.event == original.event)
        #expect(decoded.payload == original.payload)
        #expect(decoded.raw == original.raw)
        let sent = try #require(decoded.sentAt)
        #expect(abs(sent.timeIntervalSince(sentAt)) < 0.002)   // millisecond precision on the wire
    }

    @Test func wireUsesSortedKeysAndDottedEventNames() throws {
        let event = HookEvent(thread: "3f9a2c17be04", event: .turnStarted, payload: ["b": "2", "a": "1"], sentAt: nil)
        let text = String(decoding: try event.encoded(), as: UTF8.self)
        #expect(text.contains(#""event" : "turn.started""#) || text.contains(#""event":"turn.started""#))
        let aIndex = try #require(text.range(of: #""a""#)).lowerBound
        let bIndex = try #require(text.range(of: #""b""#)).lowerBound
        #expect(aIndex < bIndex)
        #expect(!text.contains("\\/"))
    }

    @Test(arguments: [
        ("turn.started", HookEvent.Kind.turnStarted),
        ("turn.ended", .turnEnded),
        ("input.requested", .inputRequested),
        ("permission.requested", .permissionRequested),
        ("thread.ended", .threadEnded),
    ])
    func everyKindDecodesFromItsWireString(wire: String, kind: HookEvent.Kind) throws {
        let json = #"{ "thread" : "3f9a2c17be04", "event" : "\#(wire)", "payload" : {} }"#
        let decoded = try HookEvent.decode(Data(json.utf8))
        #expect(decoded.event == kind)
        #expect(decoded.sentAt == nil)
        #expect(decoded.raw == nil)
        #expect(HookEvent.Kind(rawValue: wire) == kind)
    }

    @Test func allCasesCoverTheFiveEvents() {
        #expect(HookEvent.Kind.allCases.count == 5)
    }

    @Test func unknownKindFails() {
        let json = #"{ "thread" : "3f9a2c17be04", "event" : "turn.paused", "payload" : {} }"#
        #expect(throws: (any Error).self) { try HookEvent.decode(Data(json.utf8)) }
    }

    @Test func blueprintExampleDecodes() throws {
        let json = """
        { "thread" : "3f9a2c17be04", "event" : "input.requested", "payload" : { "reason" : "permission", "tool" : "Bash" },
          "sentAt" : "2026-09-07T11:41:02.771Z", "raw" : "{\\"session_id\\":\\"…\\",\\"hook_event_name\\":\\"Notification\\"}" }
        """
        let decoded = try HookEvent.decode(Data(json.utf8))
        #expect(decoded.thread == "3f9a2c17be04")
        #expect(decoded.event == .inputRequested)
        #expect(decoded.payload["tool"] == "Bash")
        #expect(decoded.sentAt != nil)
        #expect(decoded.raw?.contains("Notification") == true)
    }

    @Test func sentAtWithoutFractionalSecondsIsAccepted() throws {
        let json = #"{ "thread" : "3f9a2c17be04", "event" : "turn.ended", "payload" : {}, "sentAt" : "2026-09-07T11:41:02Z" }"#
        let decoded = try HookEvent.decode(Data(json.utf8))
        let sent = try #require(decoded.sentAt)
        #expect(Calendar(identifier: .iso8601).component(.second, from: sent) == 2)
    }

    @Test func nullSentAtAndRawDecodeAsNil() throws {
        let json = #"{ "thread" : "3f9a2c17be04", "event" : "turn.ended", "payload" : {}, "sentAt" : null, "raw" : null }"#
        let decoded = try HookEvent.decode(Data(json.utf8))
        #expect(decoded.sentAt == nil)
        #expect(decoded.raw == nil)
    }

    @Test func adapterEventRequiresAWellFormedThreadID() throws {
        let good = HookEvent(thread: "3f9a2c17be04", event: .turnEnded, payload: ["k": "v"], raw: "x")
        let event = try #require(AdapterEvent(good, receivedAt: Date(timeIntervalSince1970: 10)))
        #expect(event.threadID.rawValue == "3f9a2c17be04")
        #expect(event.kind == .turnEnded)
        #expect(event.payload == ["k": "v"])
        #expect(event.raw == "x")
        #expect(event.receivedAt == Date(timeIntervalSince1970: 10))

        #expect(AdapterEvent(HookEvent(thread: "", event: .turnEnded)) == nil)
        #expect(AdapterEvent(HookEvent(thread: "not-hex", event: .turnEnded)) == nil)
        #expect(AdapterEvent(HookEvent(thread: "3F9A2C17BE04", event: .turnEnded)) == nil)
    }

    @Test func reasonComesFromThePayload() throws {
        let id = ThreadID.generate()
        #expect(AdapterEvent(threadID: id, kind: .inputRequested, payload: ["reason": "permission"]).reason == "permission")
        #expect(AdapterEvent(threadID: id, kind: .inputRequested).reason == nil)
    }
}
