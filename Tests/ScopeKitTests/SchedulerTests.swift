import Foundation
import Testing
@testable import ScopeCore

/// When a scheduled prompt fires: the next and previous occurrences of each rule, the catch-up at launch, and that a
/// run is never repeated for one occurrence. Paris time, so the daylight-saving change is in the picture.
@Suite struct SchedulerTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// `2026-10-15 09:00`, in Paris.
    static func stamp(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    @Test func dailyFiresAtTheClockTimeNextDay() {
        // Thursday 2026-10-15 10:00: 09:00 is gone, the next is tomorrow.
        let next = Scheduler.nextFire(.daily(hour: 9), after: Self.date(2026, 10, 15, 10, 0), calendar: Self.calendar)
        #expect(next.map(Self.stamp) == "2026-10-16 09:00")
        let previous = Scheduler.previousFire(.daily(hour: 9), before: Self.date(2026, 10, 15, 10, 0), calendar: Self.calendar)
        #expect(previous.map(Self.stamp) == "2026-10-15 09:00")
    }

    @Test func hourlyFiresAtTheMinute() {
        let next = Scheduler.nextFire(.hourly(minute: 5), after: Self.date(2026, 10, 15, 10, 6), calendar: Self.calendar)
        #expect(next.map(Self.stamp) == "2026-10-15 11:05")
    }

    @Test func weekdaysSkipTheWeekend() {
        // Friday 2026-10-16 after 09:00: the next weekday 09:00 is Monday the 19th.
        let next = Scheduler.nextFire(.weekdays(hour: 9), after: Self.date(2026, 10, 16, 9, 30), calendar: Self.calendar)
        #expect(next.map(Self.stamp) == "2026-10-19 09:00")
        // Sunday: the previous one is Friday.
        let previous = Scheduler.previousFire(.weekdays(hour: 9), before: Self.date(2026, 10, 18, 12, 0), calendar: Self.calendar)
        #expect(previous.map(Self.stamp) == "2026-10-16 09:00")
    }

    @Test func weeklyFiresOnItsWeekday() {
        // Monday is 2 in Calendar's numbering; from Thursday the 15th, the next Monday 09:00 is the 19th.
        let next = Scheduler.nextFire(.weekly(weekday: 2, hour: 9), after: Self.date(2026, 10, 15, 10, 0), calendar: Self.calendar)
        #expect(next.map(Self.stamp) == "2026-10-19 09:00")
    }

    @Test func aDailyRuleKeepsItsWallClockAcrossTheClockChange() {
        // Paris leaves daylight-saving time on 2026-10-25 at 03:00. 09:00 the day before and after are 25 hours apart.
        let before = Self.date(2026, 10, 24, 10, 0)
        let next = Scheduler.nextFire(.daily(hour: 9), after: before, calendar: Self.calendar)!
        #expect(Self.stamp(next) == "2026-10-25 09:00")
        let after = Scheduler.nextFire(.daily(hour: 9), after: next, calendar: Self.calendar)!
        #expect(Self.stamp(after) == "2026-10-26 09:00")
        #expect(after.timeIntervalSince(next) == 24 * 3600)
        #expect(next.timeIntervalSince(Self.date(2026, 10, 24, 9, 0)) == 25 * 3600)
    }

    @Test func dueOnlyOnceAnOccurrencePassedSinceWatching() {
        let watched = Self.date(2026, 10, 15, 8, 0)
        let schedule = Schedule(name: "morning", rule: .daily(hour: 9), prompt: "p")
        // 08:30: no occurrence yet.
        #expect(Scheduler.due([schedule], now: Self.date(2026, 10, 15, 8, 30), watchedSince: watched, catchUp: false,
                              calendar: Self.calendar).isEmpty)
        // 09:01: due.
        #expect(Scheduler.due([schedule], now: Self.date(2026, 10, 15, 9, 1), watchedSince: watched, catchUp: false,
                              calendar: Self.calendar).map(\.name) == ["morning"])
        // Ran at 09:01: not due again at 09:30, nor at 23:00.
        var ran = schedule
        ran.lastRun = ScheduleRun(at: Self.date(2026, 10, 15, 9, 1), outcome: .replied)
        #expect(Scheduler.due([ran], now: Self.date(2026, 10, 15, 9, 30), watchedSince: watched, catchUp: false,
                              calendar: Self.calendar).isEmpty)
        #expect(Scheduler.due([ran], now: Self.date(2026, 10, 15, 23, 0), watchedSince: watched, catchUp: false,
                              calendar: Self.calendar).isEmpty)
        // The next day's 09:00 is a new occurrence.
        #expect(Scheduler.due([ran], now: Self.date(2026, 10, 16, 9, 0), watchedSince: watched, catchUp: false,
                              calendar: Self.calendar).isEmpty)
        #expect(Scheduler.due([ran], now: Self.date(2026, 10, 16, 9, 1), watchedSince: watched, catchUp: false,
                              calendar: Self.calendar).map(\.name) == ["morning"])
    }

    @Test func aPausedScheduleNeverFires() {
        let paused = Schedule(name: "p", rule: .hourly(minute: 0), prompt: "p", enabled: false)
        #expect(Scheduler.due([paused], now: Self.date(2026, 10, 15, 10, 1), watchedSince: Self.date(2026, 10, 15, 9, 0),
                              catchUp: true, calendar: Self.calendar).isEmpty)
    }

    @Test func launchCatchesUpADailyMissedToday() {
        // The Mac wakes at 10:00; the 09:00 prompt is within the day, so it fires once. An hourly one does not.
        let now = Self.date(2026, 10, 15, 10, 0)
        let daily = Schedule(name: "morning", rule: .daily(hour: 9), prompt: "p")
        let hourly = Schedule(name: "tick", rule: .hourly(minute: 0), prompt: "p")
        #expect(Scheduler.due([daily, hourly], now: now, watchedSince: now, catchUp: true, calendar: Self.calendar).map(\.name) == ["morning"])
        #expect(Scheduler.due([daily, hourly], now: now, watchedSince: now, catchUp: false, calendar: Self.calendar).isEmpty)
        // Ran yesterday at 09:00: today's 09:00 is still missed. Ran today: nothing to catch up.
        var yesterday = daily
        yesterday.lastRun = ScheduleRun(at: Self.date(2026, 10, 14, 9, 0), outcome: .replied)
        #expect(Scheduler.due([yesterday], now: now, watchedSince: now, catchUp: true, calendar: Self.calendar).count == 1)
        var today = daily
        today.lastRun = ScheduleRun(at: Self.date(2026, 10, 15, 9, 2), outcome: .replied)
        #expect(Scheduler.due([today], now: now, watchedSince: now, catchUp: true, calendar: Self.calendar).isEmpty)
        // A weekly prompt missed two days ago is history, not a catch-up.
        let weekly = Schedule(name: "weekly", rule: .weekly(weekday: 3, hour: 9), prompt: "p")  // Tuesday the 13th
        #expect(Scheduler.due([weekly], now: now, watchedSince: now, catchUp: true, calendar: Self.calendar).isEmpty)
    }

    @Test func rulesAndTargetsDescribeThemselves() {
        #expect(ScheduleRule.daily(hour: 9, minute: 5).description(calendar: Self.calendar) == "daily at 09:05")
        #expect(ScheduleRule.hourly(minute: 30).description(calendar: Self.calendar) == "every hour at :30")
        #expect(ScheduleRule.weekdays(hour: 18, minute: 30).description(calendar: Self.calendar) == "weekdays at 18:30")
        #expect(ScheduleRule.weekly(weekday: 2, hour: 9).description(calendar: Self.calendar) == "weekly on Monday at 09:00")
        #expect(ScheduleTarget.orchestrator.description == "orchestrator")
        #expect(ScheduleTarget(kind: .newTask, driver: "claude-code", model: "haiku").description == "new task (claude-code · haiku)")
        #expect(ScheduleTarget(kind: .newTask).description == "new task")
    }

    @Test func aScheduleSurvivesAHandEditedConfig() throws {
        let json = #"{"name":"m","prompt":"p","rule":{"kind":"weekly","weekday":9},"target":{"kind":"newTask","driver":""},"enabled":false}"#
        let schedule = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        #expect(schedule.rule.kind == .weekly && schedule.rule.weekday == 7 && schedule.rule.hour == 9)
        #expect(schedule.target.kind == .newTask && schedule.target.driver == nil)
        #expect(!schedule.enabled && schedule.id.count == 8)
        // A rule nobody understands is daily at 09:00, not a refused config.
        let odd = try JSONDecoder().decode(Schedule.self, from: Data(#"{"name":"m","prompt":"p","rule":{"kind":"fortnightly"}}"#.utf8))
        #expect(odd.rule.kind == .daily && odd.enabled)
        // A declaration keeps its schedules, and one without any decodes.
        let declaration = try JSONDecoder().decode(ScopeDeclaration.self, from: Data(#"{"id":"8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10","path":"/tmp/a","slug":"a"}"#.utf8))
        #expect(declaration.schedules.isEmpty)
        let round = try JSONDecoder().decode(ScopeDeclaration.self, from: JSONEncoder().encode(
            ScopeDeclaration(path: "/tmp/a", slug: "a", schedules: [schedule])))
        #expect(round.schedules == [schedule])
    }

    @Test func theExamplesArePausedAndNamedForTheirMoment() {
        let examples = Schedule.examples()
        #expect(examples.map(\.name) == ["Morning: PRs with red checks", "Evening: summarize today"])
        #expect(examples.allSatisfy { !$0.enabled && $0.target.kind == .orchestrator && !$0.prompt.isEmpty })
        #expect(examples[1].prompt.contains("scope summary today"))
        #expect(examples[0].id != examples[1].id)
    }

    @Test func aScheduleMatchesItsNameOrId() {
        let schedule = Schedule(id: "0badf00d", name: "Morning", rule: .daily(hour: 9), prompt: "p")
        #expect(schedule.matches("morning") && schedule.matches(" 0badf00d ") && !schedule.matches("evening"))
    }
}
