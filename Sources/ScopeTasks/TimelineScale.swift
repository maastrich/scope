import Foundation

/// Where a date falls on a timeline `width` points wide, with the long quiet stretches folded.
///
/// A task lives minutes or days, and most of a day-long task is nobody working: drawn to scale, its turns would be
/// slivers between empty hours. So a stretch where no agent works and nothing happens to the task, longer than
/// `foldThreshold`, is *folded*: drawn as a break of fixed width (`breakWidth`) that the view labels with what it hides
/// (`⋯ 9 h`). Everything else shares the remaining width in proportion to time. A wait still shows inside a fold —
/// squeezed with it — so a question left unanswered overnight is not hidden, only shortened.
///
/// Only the longest quiet stretches fold, at most one per `pointsPerFold` of width, so a narrow inspector shows a few
/// clear breaks rather than a row of them.
public struct TimelineScale: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var x0: Double
        public var x1: Double
        public var folded: Bool

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// A quiet stretch shorter than this is drawn to scale.
    public static let foldThreshold: TimeInterval = 60 * 60
    public static let breakWidth: Double = 18
    public static let pointsPerFold: Double = 48
    /// Folds never take more than this share of the width.
    public static let maximumFoldShare = 0.5

    public let start: Date
    public let end: Date
    public let width: Double
    /// Contiguous, in time order, covering `start...end` and `0...width`.
    public let segments: [Segment]

    public var folds: [Segment] { segments.filter(\.folded) }

    /// - Parameter activity: what must stay readable — the turns and the ticks. Each is padded a little, so a tick is
    ///   never drawn on the edge of a break.
    public init(start: Date, end: Date, width: Double, activity: [DateInterval],
                foldThreshold: TimeInterval = TimelineScale.foldThreshold, breakWidth: Double = TimelineScale.breakWidth) {
        let end = max(end, start)
        self.start = start
        self.end = end
        self.width = max(0, width)
        let total = end.timeIntervalSince(start)
        guard total > 0 else {
            segments = [Segment(start: start, end: end, x0: 0, x1: self.width, folded: false)]
            return
        }

        let pad = max(60, total * 0.01)
        let busy = Self.merged(activity.map { DateInterval(start: max(start, $0.start.addingTimeInterval(-pad)),
                                                           end: min(end, max(start, $0.end.addingTimeInterval(pad)))) })
        var quiet: [DateInterval] = []
        var cursor = start
        for interval in busy {
            if interval.start > cursor { quiet.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if cursor < end { quiet.append(DateInterval(start: cursor, end: end)) }

        // Nothing happened at all: folding would leave nothing to scale.
        let limit = busy.isEmpty ? 0 : max(0, Int(self.width / Self.pointsPerFold))
        let folded = quiet.filter { $0.duration >= foldThreshold }
            .sorted { $0.duration > $1.duration }
            .prefix(limit)
            .sorted { $0.start < $1.start }
        let foldWidth = folded.isEmpty ? 0 : min(breakWidth, self.width * Self.maximumFoldShare / Double(folded.count))
        let linearTime = total - folded.map(\.duration).reduce(0, +)
        let linearWidth = self.width - foldWidth * Double(folded.count)

        var segments: [Segment] = []
        var x = 0.0
        var at = start
        func add(_ until: Date, folded isFold: Bool) {
            guard until > at else { return }
            let span = until.timeIntervalSince(at)
            let w = isFold ? foldWidth : (linearTime > 0 ? linearWidth * span / linearTime : 0)
            segments.append(Segment(start: at, end: until, x0: x, x1: x + w, folded: isFold))
            x += w
            at = until
        }
        for fold in folded {
            add(fold.start, folded: false)
            add(fold.end, folded: true)
        }
        add(end, folded: false)
        // Rounding: the last segment ends on the edge.
        if !segments.isEmpty { segments[segments.count - 1].x1 = self.width }
        self.segments = segments
    }

    /// The x of `date`, clamped to the timeline; linear inside each segment, folds included.
    public func x(_ date: Date) -> Double {
        if date <= start { return 0 }
        if date >= end { return width }
        guard let segment = segments.first(where: { date <= $0.end }) else { return width }
        guard segment.duration > 0 else { return segment.x0 }
        return segment.x0 + (segment.x1 - segment.x0) * date.timeIntervalSince(segment.start) / segment.duration
    }

    /// The date under `x`: the inverse of `x(_:)`.
    public func date(atX x: Double) -> Date {
        if x <= 0 { return start }
        if x >= width { return end }
        guard let segment = segments.first(where: { x <= $0.x1 }) else { return end }
        let w = segment.x1 - segment.x0
        guard w > 0 else { return segment.start }
        return segment.start.addingTimeInterval(segment.duration * (x - segment.x0) / w)
    }

    /// The horizontal extent of `start...end`, at least `minimumWidth` wide so a turn of seconds stays visible and
    /// hoverable at the inspector's narrowest. Kept inside the timeline.
    public func extent(from spanStart: Date, to spanEnd: Date, minimumWidth: Double = 2) -> ClosedRange<Double> {
        var lower = x(spanStart), upper = x(spanEnd)
        if upper - lower < minimumWidth {
            let middle = (lower + upper) / 2
            lower = min(max(0, middle - minimumWidth / 2), max(0, width - minimumWidth))
            upper = min(width, lower + minimumWidth)
        }
        return lower...upper
    }

    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }
}
