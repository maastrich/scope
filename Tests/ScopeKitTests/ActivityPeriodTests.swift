import Foundation
import Testing
@testable import ScopeControl

/// What `/scope-summary <period>` means by its words, on a fixed clock in a fixed time zone.
@Suite struct ActivityPeriodTests {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    static let calendar = ActivityPeriod.calendar(paris)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// Thursday 15 October 2026, mid-morning.
    static let now = date(2026, 10, 15, 10)

    static func parse(_ text: String?, now: Date = now) -> ActivityPeriod? {
        ActivityPeriod.parse(text, now: now, calendar: calendar)
    }

    static func range(_ text: String?, now: Date = now) -> (Date, Date)? {
        parse(text, now: now).map { ($0.since, $0.until) }
    }

    @Test func daysAreWholeDaysEndingAtMidnight() {
        #expect(Self.range("today")! == (Self.date(2026, 10, 15), Self.date(2026, 10, 16)))
        #expect(Self.range("yesterday")! == (Self.date(2026, 10, 14), Self.date(2026, 10, 15)))
    }

    @Test func lastWeekIsThePreviousCalendarWeekFromMonday() {
        #expect(Self.range("last week")! == (Self.date(2026, 10, 5), Self.date(2026, 10, 12)))
        #expect(Self.range("this week")! == (Self.date(2026, 10, 12), Self.date(2026, 10, 19)))
        #expect(Self.calendar.component(.weekday, from: Self.parse("this week")!.since) == 2, "a Monday")
    }

    @Test func weeksStartOnMondayWhateverTheLocale() {
        var american = Calendar(identifier: .gregorian)
        american.locale = Locale(identifier: "en_US")
        american.timeZone = Self.paris
        #expect(american.firstWeekday == 1, "the trap: Sunday first")
        // The parser uses its own calendar, never the one a locale would hand it.
        #expect(Self.calendar.firstWeekday == 2)
    }

    @Test func monthsAndYearsAreCalendarOnes() {
        #expect(Self.range("this month")! == (Self.date(2026, 10, 1), Self.date(2026, 11, 1)))
        #expect(Self.range("last month")! == (Self.date(2026, 9, 1), Self.date(2026, 10, 1)))
        #expect(Self.range("last year")! == (Self.date(2025, 1, 1), Self.date(2026, 1, 1)))
    }

    @Test func rollingPeriodsEndWithToday() {
        #expect(Self.range("last 7 days")! == (Self.date(2026, 10, 9), Self.date(2026, 10, 16)))
        #expect(Self.range("past 3 days")! == (Self.date(2026, 10, 13), Self.date(2026, 10, 16)))
        #expect(Self.range("2w")! == (Self.date(2026, 10, 2), Self.date(2026, 10, 16)))
        #expect(Self.range("7d")! == Self.range("last 7 days")!)
    }

    @Test func noWordsIsTheLastSevenDays() {
        let period = Self.parse(nil)!
        #expect(period.label == "last 7 days")
        #expect((period.since, period.until) == Self.range("last 7 days")!)
        #expect(Self.parse("   ")?.label == "last 7 days")
    }

    @Test func isoDatesMonthsAndRangesIncludeBothEnds() {
        #expect(Self.range("2026-10-01")! == (Self.date(2026, 10, 1), Self.date(2026, 10, 2)))
        #expect(Self.range("2026-10")! == (Self.date(2026, 10, 1), Self.date(2026, 11, 1)))
        #expect(Self.range("2026-10-01..2026-10-14")! == (Self.date(2026, 10, 1), Self.date(2026, 10, 15)))
        #expect(Self.range("2026-10-01 to 2026-10-14")! == Self.range("2026-10-01..2026-10-14")!)
        #expect(Self.range("2026-09..2026-10")! == (Self.date(2026, 9, 1), Self.date(2026, 11, 1)))
        #expect(Self.range("since 2026-10-01")! == (Self.date(2026, 10, 1), Self.date(2026, 10, 16)))
        #expect(Self.range("2026-10-01..")! == Self.range("since 2026-10-01")!)
    }

    @Test func caseAndSpacingDoNotMatterAndTheLabelKeepsTheUsersWords() {
        let period = Self.parse("  Last   Week ")!
        #expect((period.since, period.until) == Self.range("last week")!)
        #expect(period.label == "Last Week")
    }

    /// The week holding the end of daylight saving time is 7 days and one hour long: counted by the calendar, it still
    /// starts and ends at midnight.
    @Test func aWeekAcrossTheClockChangeStillEndsAtMidnight() {
        let period = Self.parse("last week", now: Self.date(2026, 10, 28, 12))!
        #expect((period.since, period.until) == (Self.date(2026, 10, 19), Self.date(2026, 10, 26)))
        #expect(period.until.timeIntervalSince(period.since) == 7 * 86_400 + 3_600)
    }

    @Test func nonsenseIsRefused() {
        for text in ["someday", "last fortnight", "2026-13-01", "2026-02-30", "2026-10-14..2026-10-01", "0 days", "26-10-01"] {
            #expect(Self.parse(text) == nil, "\(text)")
        }
    }

    @Test func untilIsExcluded() {
        let period = Self.parse("yesterday")!
        #expect(period.contains(Self.date(2026, 10, 14)))
        #expect(period.contains(Self.date(2026, 10, 14, 23)))
        #expect(!period.contains(Self.date(2026, 10, 15)))
    }
}
