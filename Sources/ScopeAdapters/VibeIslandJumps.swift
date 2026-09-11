import Darwin
import Foundation
import ScopeCore
import Synchronization

/// One click on a Vibe Island session card, as Vibe Island logs it.
///
/// Vibe Island (1.0.48) never tells the app it jumps to *which* session was clicked: its custom jump rules
/// (`~/.vibe-island/integrations.json`) are never read, so for Scope a click only activates the app. What it does
/// do is log every jump to `~/Library/Logs/VibeIsland/vibe-island.log`, one JSON object per line:
///
/// ```
/// {"c":"jump","m":"jump-shadow: session=bffb9897 bundle=dev.<user>.scope.debug … planned=noLocalHandle(noClues)","t":"2026-09-11T08:32:30.727Z"}
/// {"c":"jump","m":"jump route decided","d":{"session":"e8a9b5ece5a6", …},"t":"…"}
/// {"c":"jump","m":"jump: bid=dev.<user>.scope.debug iterm=nil tmux=false … tty=\/dev\/ttys012 … pid=53462 …","t":"…"}
/// ```
///
/// The shadow line carries the first characters of the driver's session id, the `jump:` line the driver
/// process's pid and tty. The route line's `session` is Vibe Island's own key, not the driver's: never use it.
public struct VibeIslandJump: Equatable, Sendable {
    public var date: Date
    /// The app the jump targets as logged, with the user name scrubbed (`dev.<user>.scope.debug`). Informational:
    /// matching goes through the session and the pid, which do not depend on how Vibe Island scrubs its logs.
    public var bundle: String?
    /// Lowercase head of the driver's session id (`bffb9897`).
    public var sessionPrefix: String?
    public var pid: pid_t?
    public var tty: String?

    public init(date: Date, bundle: String? = nil, sessionPrefix: String? = nil, pid: pid_t? = nil, tty: String? = nil) {
        self.date = date
        self.bundle = bundle
        self.sessionPrefix = sessionPrefix
        self.pid = pid
        self.tty = tty
    }

    /// The thread the click was for: the only one whose driver session starts with `sessionPrefix`, else the one
    /// whose PTY child is `pid` or an ancestor of it.
    ///
    /// `nil` for a click on another app's session, or on a thread of another running Scope: every instance reads
    /// the same log, and only the one owning the session may react.
    public func resolve(_ candidates: [ThreadLink.Candidate], parent: (pid_t) -> pid_t? = ThreadLink.parentPID(of:)) -> ThreadID? {
        var matches: [ThreadLink.Candidate] = []
        if let sessionPrefix {
            matches = candidates.filter { $0.sessionID?.lowercased().hasPrefix(sessionPrefix) == true }
            if matches.count == 1 { return matches[0].id }
        }
        if let pid, let id = ThreadLink(pid: pid).resolve(candidates, parent: parent) {
            return id
        }
        // Two records share the head of a session (a thread resumed into another) and the pid is gone: the running one.
        return matches.first(where: { $0.pid != nil })?.id
    }
}

/// Reads Vibe Island's log incrementally and turns its jump lines into ``VibeIslandJump``s.
///
/// Only the bytes appended since the last read are parsed. A read may end mid-line and the two lines of a click
/// may land in different reads, so both the partial line and the last shadow line are carried over.
public struct VibeIslandJumpLog: Sendable {
    /// `~/Library/Logs/VibeIsland/vibe-island.log`
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Logs/VibeIsland/vibe-island.log", directoryHint: .notDirectory)
    }

    /// A jump older than this is history (a replay after rotation, a read that came late), not a click to follow.
    static let maxAge: TimeInterval = 5
    /// The shadow line precedes its `jump:` line by a few milliseconds; further apart, they are two clicks.
    static let pairing: TimeInterval = 2
    /// Most bytes parsed in one read; a larger backlog is skipped down to its tail.
    static let maxRead = 1 << 20

    private struct Shadow: Sendable {
        var date: Date
        var bundle: String?
        var sessionPrefix: String?
    }

    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var partial = Data()
    private var skipsFirstLine = false
    private var shadow: Shadow?

    /// Starts at the end of `url`: jumps logged before Scope started are not clicks for it.
    public init(startingAtEndOf url: URL) {
        if let (size, id) = Self.stat(url) {
            offset = size
            fileID = id
        }
    }

    /// Starts at the beginning of whatever file is read first.
    init() {}

    /// The fresh jumps appended to `url` since the last read.
    public mutating func read(_ url: URL, now: Date = .now) -> [VibeIslandJump] {
        guard let (size, id) = Self.stat(url) else { return [] }
        if id != fileID || size < offset {
            // Rotated (`vibe-island.log` renamed to `.log.1` and started afresh) or truncated: read the new file
            // from its start; `maxAge` keeps anything old in it from being followed.
            fileID = id
            offset = 0
            partial = Data()
            shadow = nil
            skipsFirstLine = false
        }
        guard size > offset else { return [] }
        if size - offset > UInt64(Self.maxRead) {
            offset = size - UInt64(Self.maxRead)
            partial = Data()
            skipsFirstLine = true
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset))
        else { return [] }
        offset += UInt64(data.count)
        return consume(data, now: now)
    }

    /// Parses appended bytes; the trailing partial line waits for the next call.
    mutating func consume(_ data: Data, now: Date) -> [VibeIslandJump] {
        partial.append(data)
        var jumps: [VibeIslandJump] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = Data(partial[partial.startIndex..<newline])
            partial = Data(partial[partial.index(after: newline)...])
            if skipsFirstLine {
                skipsFirstLine = false
                continue
            }
            if let jump = parse(line), abs(now.timeIntervalSince(jump.date)) <= Self.maxAge {
                jumps.append(jump)
            }
        }
        if partial.count > Self.maxRead { partial = Data() }
        return jumps
    }

    private mutating func parse(_ line: Data) -> VibeIslandJump? {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["c"] as? String == "jump",
              let message = object["m"] as? String,
              let stamp = object["t"] as? String,
              let date = Self.date(stamp)
        else { return nil }

        if message.hasPrefix("jump-shadow:") {
            let fields = Self.fields(message)
            shadow = Shadow(date: date, bundle: fields["bundle"], sessionPrefix: Self.sessionPrefix(fields["session"]))
            return nil
        }
        guard message.hasPrefix("jump:") else { return nil }
        let fields = Self.fields(message)
        guard let bundle = fields["bid"] else { return nil }   // `jump: done 12ms` and the like

        var jump = VibeIslandJump(date: date, bundle: bundle,
                                  pid: fields["pid"].flatMap { pid_t($0) }.flatMap { $0 > 1 ? $0 : nil },
                                  tty: fields["tty"])
        if let shadow, abs(date.timeIntervalSince(shadow.date)) <= Self.pairing,
           shadow.bundle == nil || shadow.bundle == bundle {
            jump.sessionPrefix = shadow.sessionPrefix
        }
        shadow = nil
        guard jump.sessionPrefix != nil || jump.pid != nil else { return nil }
        return jump
    }

    /// `key=value` words of a log message; `nil`, `-` and empty values are dropped.
    static func fields(_ message: String) -> [String: String] {
        var fields: [String: String] = [:]
        for word in message.split(separator: " ") {
            guard let separator = word.firstIndex(of: "="), separator != word.startIndex else { continue }
            let key = String(word[..<separator])
            let value = String(word[word.index(after: separator)...])
            // First occurrence wins: later words like `legacy=activateAppFallback(bundleId: …)` repeat nothing useful.
            guard !value.isEmpty, value != "nil", value != "-", fields[key] == nil else { continue }
            fields[key] = value
        }
        return fields
    }

    /// Lowercase hex (dashes allowed), at least 6 characters: short enough heads would match anything.
    static func sessionPrefix(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), raw.count >= 6,
              raw.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { return nil }
        return raw
    }

    static func date(_ stamp: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
            ?? (try? Date.ISO8601FormatStyle().parse(stamp))
    }

    private static func stat(_ url: URL) -> (size: UInt64, id: UInt64?)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        return (size, (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}

/// Follows Vibe Island's log and hands every fresh jump to `sink` on the main actor.
///
/// A kqueue source on the file itself, not FSEvents: Vibe Island keeps its log open and appends to it, and FSEvents
/// reports none of those writes (the file grew for seconds without a single event), while `.extend` fires on each.
/// When the file is rotated away (`.rename`, `.delete`) the source is re-armed on the new one.
///
/// Reacting to the file, not to Scope's activation, matters: the jump is logged just before Vibe Island activates
/// the app, and a click can land while Scope is already frontmost.
public final class VibeIslandJumpWatcher: Sendable {
    private struct State {
        var log: VibeIslandJumpLog
        var source: (any DispatchSourceFileSystemObject)?
        var stopped = false
    }

    private let logURL: URL
    private let sink: @MainActor @Sendable (VibeIslandJump) -> Void
    private let state: Mutex<State>
    /// `.userInitiated`: the click always finds Scope in the background, where macOS holds lower QoS back by seconds.
    private let queue = DispatchQueue(label: "dev.scope.vibe-island-jumps", qos: .userInitiated)

    public init(logURL: URL = VibeIslandJumpLog.url(), sink: @escaping @MainActor @Sendable (VibeIslandJump) -> Void) {
        self.logURL = logURL
        self.sink = sink
        state = Mutex(State(log: VibeIslandJumpLog(startingAtEndOf: logURL)))
    }

    /// Starts watching. A no-op when Vibe Island has never run (no log folder).
    public func start() {
        guard FileManager.default.fileExists(atPath: logURL.deletingLastPathComponent().path) else { return }
        queue.async { self.arm() }
    }

    /// Stops watching. Idempotent.
    public func stop() {
        let source = state.withLock { state in
            state.stopped = true
            defer { state.source = nil }
            return state.source
        }
        source?.cancel()
    }

    /// On `queue`: opens the log and watches it; retries every second while it does not exist (between a rotation's
    /// rename and the new file, or before Vibe Island's first line).
    private func arm() {
        guard state.withLock({ !$0.stopped && $0.source == nil }) else { return }
        let descriptor = open(logURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.extend, .write, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.handleEvent() }
        source.setCancelHandler { close(descriptor) }
        state.withLock { $0.source = source }
        source.resume()
        // Lines written between the open and the resume, or the first lines of a freshly rotated file.
        deliver()
    }

    private func handleEvent() {
        let events = state.withLock { $0.source?.data } ?? []
        deliver()
        guard !events.isDisjoint(with: [.rename, .delete, .revoke]) else { return }
        let source = state.withLock { state in
            defer { state.source = nil }
            return state.source
        }
        source?.cancel()
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
    }

    private func deliver() {
        let url = logURL
        let jumps = state.withLock { $0.log.read(url) }
        guard !jumps.isEmpty else { return }
        let sink = sink
        Task { @MainActor in
            for jump in jumps { sink(jump) }
        }
    }
}
