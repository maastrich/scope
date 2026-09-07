import Foundation
import ScopeCore
import Synchronization
import Testing
@testable import ScopeAdapters

/// Server + client on a temp socket path under `$TMPDIR` (short enough for `sun_path`).
@Suite struct UnixSocketRoundTripTests {
    // MARK: helpers

    /// A fresh socket path per test so suites can run in parallel.
    static func temporarySocketPath() -> String {
        let name = "scope-test-\(UUID().uuidString.prefix(8).lowercased()).sock"
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name).path
    }

    /// Thread-safe inbox for what the server receives.
    final class Inbox<Element: Sendable>: Sendable {
        private let items = Mutex<[Element]>([])
        func append(_ element: Element) { items.withLock { $0.append(element) } }
        var all: [Element] { items.withLock { $0 } }
        var count: Int { items.withLock { $0.count } }
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` elapses.
    static func waitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// `NWListener.start` is asynchronous: retry the first connect until the server is really listening.
    static func sendRetrying(_ payload: Data, to path: String, attempts: Int = 100) async throws {
        var lastError: (any Error)?
        for _ in 0..<attempts {
            do {
                try await UnixSocketClient.send(payload, to: path, timeout: .seconds(2))
                return
            } catch let error as UnixSocketError {
                lastError = error
                guard case .unreachable = error else { throw error }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        throw lastError ?? UnixSocketError.unreachable(path: path, reason: "no attempts")
    }

    // MARK: UnixSocketServer / UnixSocketClient

    @Test func serverReceivesASwiftClientMessage() async throws {
        let path = Self.temporarySocketPath()
        let inbox = Inbox<Data>()
        let server = try UnixSocketServer(path: path, onMessage: { inbox.append($0) })
        server.start()
        defer { server.stop() }

        try await Self.sendRetrying(Data("hello from swift".utf8), to: path)
        #expect(await Self.waitUntil { inbox.count == 1 })
        #expect(inbox.all.first.map { String(decoding: $0, as: UTF8.self) } == "hello from swift")
    }

    @Test func eachConnectionIsOneWholeMessage() async throws {
        let path = Self.temporarySocketPath()
        let inbox = Inbox<String>()
        let server = try UnixSocketServer(path: path, onMessage: { inbox.append(String(decoding: $0, as: UTF8.self)) })
        server.start()
        defer { server.stop() }

        let big = String(repeating: "x", count: 200 * 1024)   // several receive() chunks
        try await Self.sendRetrying(Data("first".utf8), to: path)
        try await UnixSocketClient.send(Data(big.utf8), to: path)
        try await UnixSocketClient.send(Data("third".utf8), to: path)

        #expect(await Self.waitUntil { inbox.count == 3 })
        let received = inbox.all
        #expect(received.contains("first"))
        #expect(received.contains("third"))
        #expect(received.contains { $0.count == big.count })
    }

    @Test func plainBSDClientDelivers() async throws {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return }
        let path = Self.temporarySocketPath()
        let inbox = Inbox<Data>()
        let server = try UnixSocketServer(path: path, onMessage: { inbox.append($0) })
        server.start()
        defer { server.stop() }
        try await Self.sendRetrying(Data("warm-up".utf8), to: path)   // wait for the listener

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'from-nc' | \(nc) -U '\(path)'"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let finished = await Self.waitUntil(timeout: .seconds(5)) { !process.isRunning }
        if !finished { process.terminate() }

        #expect(await Self.waitUntil { inbox.count == 2 })
        #expect(inbox.all.map { String(decoding: $0, as: UTF8.self) }.contains("from-nc"))
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let path = Self.temporarySocketPath()
        #expect(FileManager.default.createFile(atPath: path, contents: Data("stale".utf8)))
        let inbox = Inbox<Data>()
        let server = try UnixSocketServer(path: path, onMessage: { inbox.append($0) })
        server.start()
        defer { server.stop() }

        try await Self.sendRetrying(Data("after stale".utf8), to: path)
        #expect(await Self.waitUntil { inbox.count == 1 })
    }

    @Test func stopUnlinksTheSocketFileAndIsIdempotent() async throws {
        let path = Self.temporarySocketPath()
        let server = try UnixSocketServer(path: path, onMessage: { _ in })
        server.start()
        try await Self.sendRetrying(Data("ping".utf8), to: path)
        #expect(FileManager.default.fileExists(atPath: path))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))

        await #expect(throws: UnixSocketError.self) {
            try await UnixSocketClient.send(Data("late".utf8), to: path, timeout: .seconds(1))
        }
    }

    @Test func clientFailsFastWhenNobodyListens() async throws {
        let path = Self.temporarySocketPath()
        let started = ContinuousClock.now
        await #expect(throws: UnixSocketError.self) {
            try await UnixSocketClient.send(Data("nobody".utf8), to: path, timeout: .seconds(20))
        }
        // "Fast" = well before the timeout; shared CI runners have shown ~4 s here.
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func tooLongPathIsRejectedUpFront() {
        let path = "/" + String(repeating: "p", count: 120)
        #expect(throws: UnixSocketError.pathTooLong(path)) {
            _ = try UnixSocketServer(path: path, onMessage: { _ in })
        }
    }

    @Test func oversizedPayloadIsRejectedByTheClient() async {
        let payload = Data(count: UnixSocketServer.maxMessageBytes + 1)
        await #expect(throws: UnixSocketError.payloadTooLarge(bytes: payload.count)) {
            try await UnixSocketClient.send(payload, to: Self.temporarySocketPath())
        }
    }

    // MARK: HookSocketServer

    @Test func hookServerDeliversKnownThreadsOnTheMainActorAndDropsTheRest() async throws {
        let path = Self.temporarySocketPath()
        let known = KnownThreads()
        let knownID = ThreadID.generate()
        let unknownID = ThreadID.generate()
        known.insert(knownID)

        let inbox = Inbox<AdapterEvent>()
        let onMain = Inbox<Bool>()
        let server = try HookSocketServer(path: path, isKnownThread: known.contains) { event in
            onMain.append(Thread.isMainThread)
            inbox.append(event)
        }
        #expect(server.path == path)
        server.start()
        defer { server.stop() }

        let accepted = HookEvent(thread: knownID.rawValue, event: .permissionRequested, payload: ["tool": "Bash"], raw: "{}")
        let unknown = HookEvent(thread: unknownID.rawValue, event: .turnStarted)
        let malformed = HookEvent(thread: "nope", event: .turnStarted)
        try await Self.sendRetrying(try unknown.encoded(), to: path)
        try await UnixSocketClient.send(try malformed.encoded(), to: path)
        try await UnixSocketClient.send(Data("this is not json".utf8), to: path)
        try await UnixSocketClient.send(try accepted.encoded(), to: path)

        #expect(await Self.waitUntil { inbox.count == 1 })
        try? await Task.sleep(for: .milliseconds(100))   // give the dropped ones a chance to (wrongly) show up
        let events = inbox.all
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.threadID == knownID)
        #expect(event.kind == .permissionRequested)
        #expect(event.payload == ["tool": "Bash"])
        #expect(event.raw == "{}")
        #expect(onMain.all == [true])
    }

    @Test func knownThreadsMirrorTracksInsertsAndRemovals() {
        let known = KnownThreads()
        let a = ThreadID.generate()
        let b = ThreadID.generate()
        #expect(!known.contains(a))
        known.insert(a)
        #expect(known.contains(a))
        known.replaceAll([a, b])
        #expect(known.snapshot == [a, b])
        known.remove(a)
        known.remove(a)
        #expect(known.snapshot == [b])
    }

    @Test func acceptValidatesWithoutASocket() throws {
        let id = ThreadID.generate()
        let wire = try HookEvent(thread: id.rawValue, event: .turnEnded).encoded()
        let stamp = Date(timeIntervalSince1970: 42)
        let event = try #require(HookSocketServer.accept(wire, isKnownThread: { $0 == id }, receivedAt: stamp))
        #expect(event.kind == .turnEnded)
        #expect(event.receivedAt == stamp)
        #expect(HookSocketServer.accept(wire, isKnownThread: { _ in false }) == nil)
        #expect(HookSocketServer.accept(Data("{".utf8), isKnownThread: { _ in true }) == nil)
        let badID = try HookEvent(thread: "zz", event: .turnEnded).encoded()
        #expect(HookSocketServer.accept(badID, isKnownThread: { _ in true }) == nil)
    }
}
