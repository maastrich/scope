import Foundation
import ScopeCore
import Synchronization

/// The set of thread ids the app currently owns, mirrored for the socket path.
///
/// The hook server validates every incoming thread id synchronously on Network.framework's queue, so the
/// check cannot hop to the main actor. The app keeps this mirror in sync (insert on create / restore, remove
/// on close) and hands `contains` to `HookSocketServer`.
public final class KnownThreads: Sendable {
    private let ids: Mutex<Set<ThreadID>>

    /// Creates a mirror, optionally pre-filled.
    public init(_ initial: Set<ThreadID> = []) {
        ids = Mutex(initial)
    }

    /// Adds a thread id.
    public func insert(_ id: ThreadID) {
        ids.withLock { _ = $0.insert(id) }
    }

    /// Removes a thread id (no-op when absent).
    public func remove(_ id: ThreadID) {
        ids.withLock { _ = $0.remove(id) }
    }

    /// Replaces the whole set (bootstrap).
    public func replaceAll(_ new: Set<ThreadID>) {
        ids.withLock { $0 = new }
    }

    /// `true` when `id` is known.
    public func contains(_ id: ThreadID) -> Bool {
        ids.withLock { $0.contains(id) }
    }

    /// A copy of the current set.
    public var snapshot: Set<ThreadID> {
        ids.withLock { $0 }
    }
}

/// App-side listener for `scope-hook`: decodes `HookEvent`s, drops the ones about unknown threads, and
/// forwards `AdapterEvent`s to a main-actor sink (one hop per event, decoding stays off the main thread).
public final class HookSocketServer: Sendable {
    /// The socket file the server listens on (export it as `SCOPE_SOCK`).
    public nonisolated let path: String

    private let server: UnixSocketServer

    /// Creates the server (does not listen yet; call `start()`).
    /// - Parameters:
    ///   - path: socket file path (see `SocketPath.resolve`).
    ///   - isKnownThread: synchronous check run on the socket queue; use `KnownThreads.contains`.
    ///   - sink: receives every accepted event on the main actor.
    ///   - onFailure: called when the listener fails after `start()`.
    public init(path: String,
                isKnownThread: @escaping @Sendable (ThreadID) -> Bool,
                sink: @escaping @MainActor @Sendable (AdapterEvent) -> Void,
                onFailure: (@Sendable (any Error) -> Void)? = nil) throws {
        self.path = path
        self.server = try UnixSocketServer(path: path, onMessage: { data in
            guard let event = Self.accept(data, isKnownThread: isKnownThread) else { return }
            Task { @MainActor in sink(event) }
        }, onFailure: onFailure)
    }

    /// Starts listening.
    public func start() {
        server.start()
    }

    /// Stops listening and removes the socket file.
    public func stop() {
        server.stop()
    }

    /// Decodes one wire message and validates its thread id. Pure apart from logging; `nil` means dropped.
    public static func accept(_ data: Data, isKnownThread: (ThreadID) -> Bool, receivedAt: Date = .now) -> AdapterEvent? {
        let hookEvent: HookEvent
        do {
            hookEvent = try HookEvent.decode(data)
        } catch {
            Log.hooks.warning("dropping undecodable hook message: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let event = AdapterEvent(hookEvent, receivedAt: receivedAt) else {
            Log.hooks.warning("dropping hook event with malformed thread id \(hookEvent.thread, privacy: .public)")
            return nil
        }
        guard isKnownThread(event.threadID) else {
            Log.hooks.warning("dropping hook event for unknown thread \(event.threadID.rawValue, privacy: .public)")
            return nil
        }
        Log.hooks.debug("\(event.kind.rawValue, privacy: .public) for thread \(event.threadID.rawValue, privacy: .public)")
        return event
    }
}
