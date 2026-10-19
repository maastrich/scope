import Foundation

/// Counts the time a view is on screen only while someone can be looking at it (spec §4.9).
///
/// A view's clock used to run from `onAppear` to `onDisappear`: an inspector section left open overnight logged
/// forty-seven hours. This clock pauses whenever a `Blocker` is up — the app is not frontmost, no window of it is
/// visible, the session is locked, the Mac is asleep, the person has not touched the keyboard or the mouse for a
/// while — and resumes when the last one goes. Each run between a pause and the next is a `Segment`, logged on its
/// own, so a day's time lands on that day. Pure: the app feeds it dates and blockers and writes what comes out.
public struct ScreenTimeClock: Sendable, Equatable {
    /// Why the clock is paused.
    public enum Blocker: String, Sendable, CaseIterable {
        /// Another app is frontmost.
        case inactive
        /// No window of the app is visible: hidden, minimized, fully covered, on another Space.
        case hidden
        /// The session is locked (the lock screen is up).
        case locked
        /// The Mac or its displays are asleep.
        case asleep
        /// No keyboard or pointer input for `idleThreshold`.
        case idle
    }

    /// How long without any input counts as having left. Reading a diff or a long answer without touching anything
    /// for a minute is ordinary; past two it is far more likely the person is elsewhere. The threshold only decides
    /// what counts as a pause: once idle is noticed, the segment is cut back at the last input, so the idle minutes
    /// themselves are never counted whatever the threshold is.
    public static let idleThreshold: TimeInterval = 120

    /// One counted run of a view.
    public struct Segment: Sendable, Equatable {
        public var id: String
        public var start: Date
        public var end: Date
        /// `true` for every segment of an opening after its first: the report counts an opening once.
        public var resumed: Bool

        public var duration: TimeInterval { end.timeIntervalSince(start) }

        public init(id: String, start: Date, end: Date, resumed: Bool) {
            self.id = id
            self.start = start
            self.end = end
            self.resumed = resumed
        }
    }

    private struct Open: Sendable, Equatable {
        /// The start of the run being counted; `nil` while paused.
        var segmentStart: Date?
        /// A segment of this opening was already logged, so the next one is a continuation.
        var emitted = false
    }

    private var open: [String: Open] = [:]
    public private(set) var blockers: Set<Blocker>

    public init(blockers: Set<Blocker> = []) {
        self.blockers = blockers
    }

    /// `true` while nothing pauses the clock.
    public var counting: Bool { blockers.isEmpty }

    public var openIDs: [String] { open.keys.sorted() }

    public func isOpen(_ id: String) -> Bool { open[id] != nil }

    /// A view appeared. Opening one already open changes nothing.
    public mutating func open(_ id: String, at date: Date) {
        guard open[id] == nil else { return }
        open[id] = Open(segmentStart: counting ? date : nil)
    }

    /// A view went away: its last run, or an empty one when nothing of this opening was counted yet, so the
    /// opening itself is still on record. `nil` for a view that was not open, or whose runs were all logged.
    public mutating func close(_ id: String, at date: Date) -> Segment? {
        guard let state = open.removeValue(forKey: id) else { return nil }
        return segment(id, state: state, end: date)
    }

    /// Every open view's last run, as at quit.
    public mutating func closeAll(at date: Date) -> [Segment] {
        openIDs.compactMap { close($0, at: date) }
    }

    /// Something now stops the person from looking: every run is cut at `date` — or at its own start when `date`
    /// is before it, as when idleness is noticed after a view opened — and logged.
    public mutating func block(_ blocker: Blocker, at date: Date) -> [Segment] {
        guard blockers.insert(blocker).inserted else { return [] }
        guard blockers.count == 1 else { return [] }
        var segments: [Segment] = []
        for id in openIDs {
            guard var state = open[id] else { continue }
            if let segment = segment(id, state: state, end: date) { segments.append(segment) }
            state.segmentStart = nil
            state.emitted = true
            open[id] = state
        }
        return segments
    }

    /// The blocker went; when it was the last one, every open view starts a new run at `date`.
    public mutating func unblock(_ blocker: Blocker, at date: Date) {
        guard blockers.remove(blocker) != nil, blockers.isEmpty else { return }
        for id in open.keys { open[id]?.segmentStart = date }
    }

    public mutating func set(_ blocker: Blocker, _ on: Bool, at date: Date) -> [Segment] {
        if on { return block(blocker, at: date) }
        unblock(blocker, at: date)
        return []
    }

    /// The run of `state` ending at `end`: nothing for a paused opening already logged; an empty one for an
    /// opening never logged, so it still counts as opened.
    private func segment(_ id: String, state: Open, end: Date) -> Segment? {
        guard let start = state.segmentStart else {
            return state.emitted ? nil : Segment(id: id, start: end, end: end, resumed: false)
        }
        let cut = max(start, end)
        guard cut > start || !state.emitted else { return nil }
        return Segment(id: id, start: start, end: cut, resumed: state.emitted)
    }
}
