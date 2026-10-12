import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

/// One socket, one listener. A second server on a path somebody answers on used to unlink it and take every
/// hook and control message meant for the first, silently.
@Suite struct SocketOwnershipTests {
    private typealias Support = UnixSocketRoundTripTests

    @Test func aLiveSocketIsNeverTakenOver() async throws {
        let path = Support.temporarySocketPath()
        let first = Support.Inbox<Data>()
        let owner = try UnixSocketServer(path: path, onMessage: { first.append($0) })
        owner.start()
        defer { owner.stop() }
        try await Support.sendRetrying(Data("before".utf8), to: path)
        #expect(UnixSocketServer.isListening(at: path))

        let second = Support.Inbox<Data>()
        #expect(throws: UnixSocketError.addressInUse(path: path)) {
            _ = try UnixSocketServer(path: path, onMessage: { second.append($0) })
        }

        // The owner still holds the path, and the probe did not reach it as a message.
        try await UnixSocketClient.send(Data("after".utf8), to: path)
        #expect(await Support.waitUntil { first.count == 2 })
        #expect(first.all.map { String(decoding: $0, as: UTF8.self) } == ["before", "after"])
        #expect(second.count == 0)
    }

    @Test func aSocketNobodyAnswersOnIsNotListening() async throws {
        let path = Support.temporarySocketPath()
        #expect(!UnixSocketServer.isListening(at: path))

        // What a crashed app leaves behind: the file, and nobody behind it.
        let server = try UnixSocketServer(path: path, onMessage: { _ in })
        server.start()
        try await Support.sendRetrying(Data("x".utf8), to: path)
        let copy = path + ".stale"
        defer { unlink(copy) }
        #expect(link(path, copy) == 0)
        server.stop()
        #expect(await Support.waitUntil { !UnixSocketServer.isListening(at: copy) })
        #expect(FileManager.default.fileExists(atPath: copy))

        let replacement = try UnixSocketServer(path: copy, onMessage: { _ in })
        replacement.start()
        defer { replacement.stop() }
        try await Support.sendRetrying(Data("y".utf8), to: copy)
        #expect(UnixSocketServer.isListening(at: copy))
    }

    @Test func aPlainFileIsNotListening() throws {
        let path = Support.temporarySocketPath()
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: path))
        defer { unlink(path) }
        #expect(!UnixSocketServer.isListening(at: path))
    }

    /// The two builds derive their socket from their home, so they listen side by side.
    @Test func twoHomesListenSideBySide() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "so-\(UUID().uuidString.prefix(6))")
        let release = root.appending(path: ".scope", directoryHint: .isDirectory)
        let debug = root.appending(path: ".scope-debug", directoryHint: .isDirectory)
        for home in [release, debug] { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }

        let releasePath = SocketPath.resolve(home: release)
        let debugPath = SocketPath.resolve(home: debug)
        #expect(releasePath != debugPath)

        let releaseInbox = Support.Inbox<Data>()
        let debugInbox = Support.Inbox<Data>()
        let releaseServer = try UnixSocketServer(path: releasePath, onMessage: { releaseInbox.append($0) })
        let debugServer = try UnixSocketServer(path: debugPath, onMessage: { debugInbox.append($0) })
        releaseServer.start()
        debugServer.start()
        defer { releaseServer.stop(); debugServer.stop() }

        try await Support.sendRetrying(Data("to release".utf8), to: releasePath)
        try await Support.sendRetrying(Data("to debug".utf8), to: debugPath)
        #expect(await Support.waitUntil { releaseInbox.count == 1 && debugInbox.count == 1 })
        #expect(releaseInbox.all == [Data("to release".utf8)])
        #expect(debugInbox.all == [Data("to debug".utf8)])
    }
}
