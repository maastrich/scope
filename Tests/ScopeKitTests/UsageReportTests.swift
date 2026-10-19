import Foundation
import Testing
@testable import ScopeControl
@testable import ScopeCore

/// `scope usage`: counting, what was never used, how commands were reached, who called the socket, time on screen,
/// and the comparison with the period before.
@Suite struct UsageReportTests {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    static let calendar = ActivityPeriod.calendar(paris)

    static func date(_ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    /// Monday 12 → Monday 19 October; the period before is 5 → 12.
    static let week = ActivityPeriod(label: "this week", since: date(12, 0), until: date(19, 0))

    static func event(_ id: String, _ kind: UsageEvent.Kind = .click, _ source: UsageEvent.Source = .mouse,
                      day: Int = 14, duration: Double? = nil) -> UsageEvent {
        UsageEvent(at: date(day), kind: kind, id: id, source: source, duration: duration)
    }

    static let registry = UsageRegistry(elements: [
        "sidebar.thread": UsageElement(id: "sidebar.thread", label: "Thread row"),
        "sidebar.repo": UsageElement(id: "sidebar.repo", label: "Repository row"),
        "command.new-thread": UsageElement(id: "command.new-thread", label: "New Thread"),
        "inspector.base": UsageElement(id: "inspector.base", label: "Base"),
    ])

    static func build(_ events: [UsageEvent], previous: [UsageEvent] = [], area: String? = nil, limit: Int = 20) -> UsageResult {
        UsageReport.build(period: week, timeZone: paris, events: events, previousEvents: previous, registry: registry,
                          historySince: date(1), area: area, limit: limit)
    }

    @Test func thePreviousPeriodIsTheSameSpanJustBefore() {
        let previous = UsageReport.previous(of: Self.week)
        #expect(previous.since == Self.date(5, 0))
        #expect(previous.until == Self.week.since)
    }

    @Test func topElementsAreCountedAndGroupedByArea() {
        let result = Self.build([
            Self.event("sidebar.thread"), Self.event("sidebar.thread"), Self.event("sidebar.task"),
            Self.event("command.new-thread", .shortcut, .keyboard),
            Self.event("sidebar.thread", day: 20), // after the period
        ])
        #expect(result.total == 4)
        #expect(result.top.first == .init(id: "sidebar.thread", label: "Thread row", area: "sidebar", count: 2, previous: 0))
        #expect(result.areas.map(\.area) == ["sidebar", "command"])
        #expect(result.areas.first?.count == 3)
        #expect(result.areas.first?.top.map(\.id) == ["sidebar.thread", "sidebar.task"])
    }

    @Test func neverUsedComesFromTheRegistry() {
        let result = Self.build([Self.event("sidebar.thread"), Self.event("command.new-thread", .menu, .menu)])
        #expect(result.neverUsed.map(\.id) == ["inspector.base", "sidebar.repo"])
        #expect(Self.build([], area: "sidebar").neverUsed.map(\.id) == ["sidebar.repo", "sidebar.thread"])
    }

    @Test func eachCommandSaysHowItWasReached() {
        let result = Self.build([
            Self.event("command.new-thread", .shortcut, .keyboard),
            Self.event("command.new-thread", .shortcut, .keyboard),
            Self.event("command.new-thread", .menu, .menu),
            Self.event("command.new-thread", .palette, .palette),
            Self.event("command.new-thread", .click, .mouse),
            Self.event("command.refresh", .palette, .palette),
        ])
        #expect(result.commands.first == .init(id: "command.new-thread", label: "New Thread",
                                               keyboard: 2, menu: 1, palette: 1, mouse: 1))
        #expect(result.commands.first?.total == 5)
        #expect(result.commands.map(\.id) == ["command.new-thread", "command.refresh"])
    }

    @Test func controlCallsAreSplitBetweenTheUserAndAgents() {
        let result = Self.build([
            Self.event("control.thread.new", .control, .agent),
            Self.event("control.thread.new", .control, .agent),
            Self.event("control.thread.new", .control, .user),
            Self.event("control.summary", .control, .user),
        ])
        #expect(result.control == [.init(method: "thread.new", user: 1, agent: 2), .init(method: "summary", user: 1, agent: 0)])
    }

    static func timed(_ id: String, _ context: String = UsageEvent.activeViewContext, duration: Double) -> UsageEvent {
        UsageEvent(at: date(14), kind: .view, id: id, source: .app, context: context, duration: duration)
    }

    @Test func viewsAddUpTheirTimeOnScreen() {
        let result = Self.build([
            Self.timed("inspector.delta", duration: 30),
            Self.timed("inspector.delta", duration: 90),
            Self.timed("sheet.graph", duration: 400),
        ])
        #expect(result.views == [.init(id: "sheet.graph", label: nil, opens: 1, seconds: 400),
                                 .init(id: "inspector.delta", label: nil, opens: 2, seconds: 120)])
    }

    /// A run after a pause is the same opening; a duration from before the clock could be a night left open.
    @Test func resumedRunsAreOneOpeningAndUntimedDurationsDoNotCount() {
        let result = Self.build([
            Self.timed("inspector.delta", duration: 30),
            Self.timed("inspector.delta", UsageEvent.resumedViewContext, duration: 45),
            Self.event("inspector.delta", .view, .mouse, duration: 47 * 3600),
        ])
        #expect(result.views == [.init(id: "inspector.delta", label: nil, opens: 2, seconds: 75)])
    }

    @Test func theReportSaysSinceWhenTimeOnScreenCanBeTrusted() {
        let events = [Self.event("inspector.delta", .view, .mouse, duration: 3600)]
        let unmeasured = UsageReport.build(period: Self.week, timeZone: Self.paris, events: events, previousEvents: [],
                                           registry: UsageRegistry(), historySince: Self.date(1))
        #expect(unmeasured.limits.first?.hasPrefix("Time on screen is not measured yet") == true)
        let measured = UsageReport.build(period: Self.week, timeZone: Self.paris, events: events, previousEvents: [],
                                         registry: UsageRegistry(), historySince: Self.date(1), screenTimeSince: Self.date(15))
        #expect(measured.screenTimeSince == Self.date(15))
        #expect(measured.limits.first?.hasPrefix("Time on screen is measured since 2026-10-15") == true)
        let before = UsageReport.build(period: Self.week, timeZone: Self.paris, events: events, previousEvents: [],
                                       registry: UsageRegistry(), historySince: Self.date(1), screenTimeSince: Self.date(2))
        #expect(!before.limits.contains { $0.hasPrefix("Time on screen is") && !$0.hasPrefix("Time on screen counts") })
    }

    @Test func settingsAreCountedByKey() {
        let result = Self.build([Self.event("setting.terminalFontSize", .setting, .mouse),
                                 Self.event("setting.terminalFontSize", .setting, .mouse)])
        #expect(result.settings.map(\.id) == ["setting.terminalFontSize"])
        #expect(result.settings.first?.count == 2)
    }

    @Test func trendsCompareWithThePeriodBefore() {
        let result = Self.build(
            [Self.event("sidebar.thread"), Self.event("sidebar.thread"), Self.event("sidebar.thread"), Self.event("sheet.graph")],
            previous: [Self.event("sidebar.thread", day: 6), Self.event("sheet.graph", day: 6), Self.event("sheet.graph", day: 6),
                       Self.event("palette.files", day: 6), Self.event("palette.files", day: 1)])
        #expect(result.previousTotal == 4, "the event of the 1st is before the previous period")
        #expect(result.rising.map(\.id) == ["sidebar.thread"])
        #expect(result.falling.map(\.id) == ["palette.files", "sheet.graph"])
        #expect(result.top.first { $0.id == "sidebar.thread" }?.previous == 1)
    }

    @Test func anAreaFilterKeepsOnlyThatArea() {
        let result = Self.build([Self.event("sidebar.thread"), Self.event("command.refresh", .menu, .menu)], area: "command")
        #expect(result.total == 1)
        #expect(result.top.map(\.id) == ["command.refresh"])
    }

    @Test func theLimitsSayWhatIsUnknown() {
        let fresh = UsageReport.build(period: Self.week, timeZone: Self.paris, events: [], previousEvents: [],
                                      registry: UsageRegistry(), recording: false, historySince: Self.date(13))
        #expect(fresh.limits.first?.contains("Recording began") == true)
        #expect(fresh.limits.contains { $0.contains("Recording is off") })
        let empty = UsageReport.build(period: Self.week, events: [], previousEvents: [], registry: UsageRegistry())
        #expect(empty.limits.first == "Nothing has been recorded yet.")
    }

    @Test func theResultSurvivesTheWireAndRendersAsText() throws {
        let result = Self.build([Self.event("command.new-thread", .shortcut, .keyboard),
                                 Self.event("control.thread.new", .control, .agent),
                                 Self.timed("sheet.graph", duration: 75)])
        let encoder = ControlProtocol.makeEncoder()
        let decoded = try ControlProtocol.makeDecoder().decode(UsageResult.self, from: encoder.encode(result))
        #expect(decoded == result)
        let text = CLIRenderer.text(.usage(result))
        #expect(text.contains("command.new-thread — New Thread"))
        #expect(text.contains("thread.new"))
        #expect(text.contains("1m15s"))
        #expect(text.contains("never used in this period"))
    }
}
