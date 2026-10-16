import SwiftUI
import ScopeAdapters
import ScopeCore
import ScopeTasks

/// The task since its creation, at a glance: agent time, time waiting for you and elapsed time above; one lane per
/// thread with its turns as bars and the waits in between tinted by what was awaited; the task's events as ticks.
/// Quiet hours fold into hatched breaks labelled with what they hide (`TimelineScale`). Hovering a bar says when, how
/// long, how it ended and what the agent said.
///
/// `compact` is the hover card's: the numbers and every lane flattened into one strip, no hover.
struct TaskTimelineView: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    var compact = false

    var body: some View {
        // `activity` is not observed: the turn revision and the state are what move when a turn opens, closes or
        // waits, and the periodic tick keeps a running bar and the "now" edge growing.
        let _ = model.threads(in: task.id).map { ($0.turnRevision, $0.displayState) }
        let _ = task.timelineLog
        TimelineView(.periodic(from: .now, by: compact ? 60 : 20)) { context in
            let timeline = model.timeline(of: task, now: context.date)
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                TimelineTotals(totals: timeline.totals, compact: compact)
                if compact {
                    TimelineStrip(timeline: timeline)
                } else if timeline.lanes.isEmpty {
                    Text("No thread has worked in this task yet.")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                } else {
                    TimelineLanes(timeline: timeline, live: task.record.archivedAt == nil)
                    TimelineLegend()
                }
            }
        }
        .task(id: task.id) {
            if task.timelineLog == nil { await model.reloadTimelineLog(of: task.id) }
        }
    }
}

// MARK: Totals

private struct TimelineTotals: View {
    let totals: TaskTimeline.Totals
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 10 : 6) {
            stat("Agent", totals.agent, color: ThreadStateStyle.running)
            stat("Waiting for you", totals.waiting, color: ThreadStateStyle.waiting)
            stat("Elapsed", totals.elapsed, color: nil)
        }
    }

    @ViewBuilder
    private func stat(_ label: String, _ seconds: TimeInterval, color: Color?) -> some View {
        if compact {
            HStack(spacing: 4) {
                if let color { Circle().fill(color).frame(width: 6, height: 6) }
                Text(DurationText.short(seconds)).font(.scopeValue).foregroundStyle(Ink.primary)
                Text(label.lowercased()).font(.scopeCaption).foregroundStyle(Ink.tertiary)
            }
            .fixedSize()
        } else {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let color { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 6, height: 6) }
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text(DurationText.short(seconds))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm))
        }
    }
}

// MARK: Colours

enum TimelineStyle {
    static func color(_ kind: TaskTimeline.Span.Kind) -> Color {
        switch kind {
        case .working: ThreadStateStyle.running
        case .waitingAnswer, .waitingPermission: ThreadStateStyle.waiting
        case .unreadResult: ThreadStateStyle.done
        }
    }

    static func color(_ tick: TaskTimeline.Tick.Kind) -> Color {
        switch tick {
        case .created, .archived: Ink.tertiary
        case .pullRequestOpened: Color.accentColor
        case .checksPassing, .merged: PullRequestStyle.passing
        case .checksFailing: PullRequestStyle.failing
        case .pullRequestClosed: PullRequestStyle.neutral
        }
    }

    /// One letter over each tick: enough to tell them apart where there is no room for words.
    static func glyph(_ tick: TaskTimeline.Tick.Kind) -> String? {
        switch tick {
        case .created, .archived: nil
        case .pullRequestOpened: "PR"
        case .checksPassing: "✓"
        case .checksFailing: "✕"
        case .merged: "M"
        case .pullRequestClosed: "C"
        }
    }

    static func label(_ kind: TaskTimeline.Span.Kind) -> String {
        switch kind {
        case .working: "Working"
        case .waitingAnswer: "Waiting for your answer"
        case .waitingPermission: "Waiting for a permission"
        case .unreadResult: "Result waiting for you"
        }
    }

    static func outcome(_ outcome: ThreadActivity.Turn.Outcome) -> String {
        switch outcome {
        case .ended: "finished"
        case .failed: "failed"
        case .inputRequested: "asked you a question"
        case .permissionRequested: "asked for a permission"
        case .interrupted: "interrupted"
        case .exited: "process exited"
        }
    }

    /// Draws one span. Waits are pale bands the full height of the lane — permissions hatched — and work a solid bar
    /// in the middle, red when the turn failed.
    static func draw(_ span: TaskTimeline.Span, in rect: CGRect, context: inout GraphicsContext) {
        switch span.kind {
        case .working:
            let bar = rect.insetBy(dx: 0, dy: rect.height * 0.18)
            let color = span.failed ? ThreadStateStyle.failed : color(span.kind)
            context.fill(Path(roundedRect: bar, cornerRadius: min(2, bar.width / 2)), with: .color(color))
            if span.running {
                // An open right edge: still going.
                let edge = CGRect(x: bar.maxX - 1, y: bar.minY - 2, width: 2, height: bar.height + 4)
                context.fill(Path(edge), with: .color(color))
            }
        case .waitingAnswer, .unreadResult:
            context.fill(Path(rect), with: .color(color(span.kind).opacity(span.kind == .unreadResult ? 0.22 : 0.30)))
        case .waitingPermission:
            context.fill(Path(rect), with: .color(color(span.kind).opacity(0.18)))
            var hatch = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                hatch.move(to: CGPoint(x: x, y: rect.maxY))
                hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 4
            }
            context.drawLayer { layer in
                layer.clip(to: Path(rect))
                layer.stroke(hatch, with: .color(color(span.kind).opacity(0.55)), lineWidth: 1)
            }
        }
    }

    /// A fold: a quiet band with two slanted cuts, the way a broken axis is drawn.
    static func drawFold(_ x0: Double, _ x1: Double, height: Double, context: inout GraphicsContext) {
        let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: height)
        context.fill(Path(rect), with: .color(Fill.quiet))
        var cuts = Path()
        for x in [x0 + (x1 - x0) * 0.35, x0 + (x1 - x0) * 0.65] {
            cuts.move(to: CGPoint(x: x - 2, y: height))
            cuts.addLine(to: CGPoint(x: x + 2, y: 0))
        }
        context.stroke(cuts, with: .color(Ink.tertiary.opacity(0.7)), lineWidth: 1)
    }
}

// MARK: Lanes

private struct TimelineLanes: View {
    let timeline: TaskTimeline
    let live: Bool
    @State private var hover: CGPoint?

    static let labelWidth: Double = 64
    static let laneHeight: Double = 16
    static let tickBand: Double = 12
    static let minimumBar: Double = 3

    var body: some View {
        GeometryReader { geometry in
            let width = max(40, geometry.size.width - Self.labelWidth)
            let scale = TimelineScale(start: timeline.start, end: timeline.end, width: width, activity: timeline.activity)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: Self.tickBand)
                    ForEach(timeline.lanes) { lane in
                        Text(lane.title)
                            .font(.system(size: 10.5))
                            .foregroundStyle(lane.closedAt == nil ? Ink.secondary : Ink.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: Self.labelWidth - 6, height: Self.laneHeight, alignment: .leading)
                            .help(lane.closedAt == nil ? lane.title : "\(lane.title) — closed")
                    }
                }
                .frame(width: Self.labelWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    canvas(scale: scale, width: width)
                        .frame(width: width, height: chartHeight)
                        .overlay(alignment: .topLeading) { tooltip(scale: scale, width: width) }
                        .onContinuousHover { phase in
                            if case .active(let point) = phase { hover = point } else { hover = nil }
                        }
                    axis(scale: scale, width: width)
                }
            }
        }
        .frame(height: chartHeight + 3 + 12)
    }

    private var chartHeight: Double { Self.tickBand + Double(timeline.lanes.count) * Self.laneHeight }

    private func laneRect(_ index: Int, _ extent: ClosedRange<Double>) -> CGRect {
        CGRect(x: extent.lowerBound, y: Self.tickBand + Double(index) * Self.laneHeight + 2,
               width: extent.upperBound - extent.lowerBound, height: Self.laneHeight - 4)
    }

    private func canvas(scale: TimelineScale, width: Double) -> some View {
        Canvas { context, size in
            for fold in scale.folds { TimelineStyle.drawFold(fold.x0, fold.x1, height: size.height, context: &context) }
            // Lane guides: a hairline per lane so an idle thread still reads as a row.
            for index in timeline.lanes.indices {
                let y = Self.tickBand + Double(index) * Self.laneHeight + Self.laneHeight / 2
                context.fill(Path(CGRect(x: 0, y: y - 0.25, width: width, height: 0.5)), with: .color(Surface.stroke.opacity(0.8)))
            }
            for (index, lane) in timeline.lanes.enumerated() {
                for span in lane.spans {
                    let extent = span.kind == .working
                        ? scale.extent(from: span.start, to: span.end, minimumWidth: Self.minimumBar)
                        : scale.x(span.start)...max(scale.x(span.start), scale.x(span.end))
                    TimelineStyle.draw(span, in: laneRect(index, extent), context: &context)
                }
            }
            for tick in timeline.ticks {
                let x = min(max(scale.x(tick.at), 0.5), width - 0.5)
                let color = TimelineStyle.color(tick.kind)
                context.fill(Path(CGRect(x: x - 0.5, y: Self.tickBand - 3, width: 1, height: size.height - Self.tickBand + 3)),
                             with: .color(color.opacity(0.55)))
                if let glyph = TimelineStyle.glyph(tick.kind) {
                    let text = context.resolve(Text(glyph).font(.system(size: 8, weight: .bold)).foregroundStyle(color))
                    let measured = text.measure(in: CGSize(width: 40, height: 12))
                    let left = min(max(0, x - measured.width / 2), width - measured.width)
                    context.draw(text, in: CGRect(x: left, y: 0, width: measured.width, height: measured.height))
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: x - 2, y: Self.tickBand - 6, width: 4, height: 4)), with: .color(color))
                }
            }
        }
    }

    /// The task's start and end, and what each fold hides.
    private func axis(scale: TimelineScale, width: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Text(Self.when(timeline.start, relativeTo: timeline.end))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(live ? "now" : Self.when(timeline.end, relativeTo: timeline.start))
                .frame(maxWidth: .infinity, alignment: .trailing)
            ForEach(Array(scale.folds.enumerated()), id: \.offset) { _, fold in
                Text("⋯ \(DurationText.short(fold.duration))")
                    .fixedSize()
                    .foregroundStyle(Ink.secondary)
                    .position(x: (fold.x0 + fold.x1) / 2, y: 6)
            }
        }
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(Ink.tertiary)
        .frame(width: width, height: 12)
    }

    static func when(_ date: Date, relativeTo other: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: other) && Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    // MARK: Hover

    private struct Hit {
        var title: String
        var lines: [String]
        var said: String?
    }

    private func hit(at point: CGPoint, scale: TimelineScale) -> Hit? {
        let index = Int((point.y - Self.tickBand) / Self.laneHeight)
        if point.y < Self.tickBand {
            // The tick band: the nearest tick within a few points.
            guard let tick = timeline.ticks.min(by: { abs(scale.x($0.at) - point.x) < abs(scale.x($1.at) - point.x) }),
                  abs(scale.x(tick.at) - point.x) <= 6 else { return nil }
            return Hit(title: tick.label, lines: [tick.at.formatted(date: .abbreviated, time: .shortened)])
        }
        guard timeline.lanes.indices.contains(index) else { return nil }
        let lane = timeline.lanes[index]
        // Work first: a bar drawn over a wait is what the pointer is on.
        let candidates = lane.spans.filter { $0.kind == .working } + lane.spans.filter(\.kind.isWait)
        guard let span = candidates.first(where: { span in
            let extent = span.kind == .working
                ? scale.extent(from: span.start, to: span.end, minimumWidth: Self.minimumBar + 2)
                : scale.x(span.start)...scale.x(span.end)
            return extent.contains(point.x)
        }) else { return nil }
        let range = "\(span.start.formatted(date: .omitted, time: .shortened)) – "
            + (span.running ? "now" : span.end.formatted(date: .omitted, time: .shortened))
        var lines = ["\(range) · \(DurationText.short(span.duration))"]
        if let turn = span.turn {
            var outcome = TimelineStyle.outcome(turn.outcome).capitalizedFirst
            if let error = turn.error { outcome += " (\(error))" }
            if turn.tools > 0 { outcome += " · \(turn.tools) tool call\(turn.tools == 1 ? "" : "s")" }
            lines.append(outcome)
            if turn.startedAt == nil { lines.append("Its start was not reported") }
        }
        let title = span.running ? "\(lane.title) — working" : "\(lane.title) — \(TimelineStyle.label(span.kind).lowercased())"
        return Hit(title: title, lines: lines, said: span.turn?.said)
    }

    @ViewBuilder
    private func tooltip(scale: TimelineScale, width: Double) -> some View {
        if let hover, let hit = hit(at: hover, scale: scale) {
            let cardWidth = min(220, width)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.primary).lineLimit(1)
                ForEach(hit.lines, id: \.self) { Text($0).font(.scopeCaption).foregroundStyle(Ink.secondary) }
                if let said = hit.said {
                    Text("“\(said)”").font(.scopeCaption).foregroundStyle(Ink.secondary).lineLimit(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: cardWidth, alignment: .leading)
            .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Surface.stroke))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .offset(x: min(max(0, hover.x - cardWidth / 2), width - cardWidth), y: chartHeight + 4)
            .allowsHitTesting(false)
            .zIndex(1)
        }
    }
}

// MARK: Legend

private struct TimelineLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            item(.working)
            item(.waitingAnswer, "answer")
            item(.waitingPermission, "permission")
            item(.unreadResult, "unread result")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Ink.tertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func item(_ kind: TaskTimeline.Span.Kind, _ label: String? = nil) -> some View {
        HStack(spacing: 3) {
            Canvas { context, size in
                TimelineStyle.draw(TaskTimeline.Span(kind: kind, start: .now, end: .now), in: CGRect(origin: .zero, size: size),
                                   context: &context)
            }
            .frame(width: 10, height: 8)
            Text(label ?? "work")
        }
    }
}

// MARK: Compact strip

/// Every lane in one strip: waits underneath, work over them.
private struct TimelineStrip: View {
    let timeline: TaskTimeline

    var body: some View {
        Canvas { context, size in
            let scale = TimelineScale(start: timeline.start, end: timeline.end, width: size.width, activity: timeline.activity)
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(Fill.quiet))
            for fold in scale.folds { TimelineStyle.drawFold(fold.x0, fold.x1, height: size.height, context: &context) }
            let spans = timeline.lanes.flatMap(\.spans)
            for span in spans.filter(\.kind.isWait) + spans.filter({ $0.kind == .working }) {
                let extent = span.kind == .working
                    ? scale.extent(from: span.start, to: span.end, minimumWidth: 2)
                    : scale.x(span.start)...max(scale.x(span.start), scale.x(span.end))
                TimelineStyle.draw(span, in: CGRect(x: extent.lowerBound, y: 0, width: extent.upperBound - extent.lowerBound,
                                                    height: size.height), context: &context)
            }
            for tick in timeline.ticks where tick.kind != .created {
                let x = min(max(scale.x(tick.at), 0.5), size.width - 0.5)
                context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(TimelineStyle.color(tick.kind)))
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Timeline of the task")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
