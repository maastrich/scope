import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters
@testable import ScopeControl

/// Tokens as `scope list`, `scope summary` and the meter print them, and their API-equivalent price.
@Suite struct TokenUsageTextTests {
    @Test func countsReadCompactly() {
        #expect(TokenUsageText.compact(0) == "0")
        #expect(TokenUsageText.compact(999) == "999")
        #expect(TokenUsageText.compact(1_000) == "1k")
        #expect(TokenUsageText.compact(1_540) == "1.5k")
        #expect(TokenUsageText.compact(12_400) == "12k")
        #expect(TokenUsageText.compact(999_999) == "1M")
        #expect(TokenUsageText.compact(1_230_000) == "1.2M")
        #expect(TokenUsageText.compact(9_960_000) == "10M")
        #expect(TokenUsageText.compact(48_700_000) == "49M")
        #expect(TokenUsageText.compact(2_100_000_000) == "2.1B")
    }

    @Test func aThreadFieldIsItsLastFiveHours() {
        var row = TokenUsageSnapshot.Row(id: "a", title: "A", scope: "s")
        row.windows.fiveHours.counts = TokenCounts(input: 200_000, output: 30_000, cacheRead: 970_000)
        row.windows.sevenDays.counts = TokenCounts(output: 9_000_000)
        #expect(TokenUsageText.threadField(row) == "1.2M · 5h")
        #expect(TokenUsageText.threadField(nil) == nil)
    }

    @Test func aBudgetIsTypedTheWayItReads() {
        #expect(TokenUsageText.budget("20M") == 20_000_000)
        #expect(TokenUsageText.budget(" 1.5m ") == 1_500_000)
        #expect(TokenUsageText.budget("500k") == 500_000)
        #expect(TokenUsageText.budget("2,000,000") == 2_000_000)
        #expect(TokenUsageText.budget("") == nil)
        #expect(TokenUsageText.budget("lots") == nil)
        #expect(TokenUsageText.budget("-5M") == nil)
    }

    @Test func thePreferencesDefaultToConsumptionOnlyAndReadAnOlderConfig() throws {
        let older = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(older.showTokenMeter)
        #expect(older.tokenBudgetPer5h == 0)
        #expect(!older.showAPICost)
        var preferences = Preferences.default
        preferences.tokenBudgetPer5h = 20_000_000
        preferences.showAPICost = true
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }

    // MARK: Price

    @Test func eachFamilyHasItsPriceAndALongerIdWinsOverItsPrefix() {
        #expect(TokenPricing.price(for: "claude-opus-5-5")?.input == 4)
        #expect(TokenPricing.price(for: "claude-opus-5")?.input == 5)
        #expect(TokenPricing.price(for: "claude-fable-5-1")?.cacheRead == 0.25)
        #expect(TokenPricing.price(for: "claude-fable-5")?.cacheRead == 1)
        #expect(TokenPricing.price(for: "claude-sonnet-4-6[1m]")?.output == 15)
        #expect(TokenPricing.price(for: "gpt-5") == nil)
    }

    @Test func cacheWritesCostMoreForAnHour() {
        let price = TokenPricing.Price(input: 4, output: 20, cacheRead: 0.2)
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000, cacheCreation: 2_000_000, cacheCreation1h: 1_000_000,
                                 cacheRead: 10_000_000)
        // 4 + 20 + 1M at 5 min (5) + 1M at 1 h (8) + 10M reads (2)
        #expect(abs(TokenPricing.dollars(counts, at: price) - 39) < 0.000_1)
    }

    @Test func unknownModelsAreLeftOutAndNamed() {
        let result = TokenPricing.dollars(byModel: [
            "claude-haiku-5-5": TokenCounts(input: 1_000_000),
            "mystery": TokenCounts(output: 5),
        ])
        #expect(abs(result.dollars - 0.1) < 0.000_1)
        #expect(result.unpriced == ["mystery"])
    }

    // MARK: Control protocol

    @Test func aThreadSummaryWithoutTokensStillDecodes() throws {
        let json = #"{"id":"a","title":"A","driver":"shell","scope":"S","scopeSlug":"s","cwd":"/","state":"idle","alive":true,"openedBy":"user","depth":0}"#
        let summary = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        #expect(summary.tokens == nil)
    }

    @Test func scopeListPrintsATokensColumn() {
        let thread = ThreadSummary(id: "aaaaaaaaaaa1", title: "fix", driver: "claude-code", scope: "Acme", scopeSlug: "acme",
                                   task: nil, cwd: "/w", state: "idle", alive: true, openedBy: "user", depth: 0, tokens: "1.2M · 5h")
        let text = CLIRenderer.text(.list(ListResult(threads: [thread])))
        #expect(text.contains("TOKENS"))
        #expect(text.contains("1.2M · 5h"))
    }

    // MARK: Summary

    typealias S = ActivitySummaryTests

    @Test func aTaskTotalsItsThreadsClosedOnesIncluded() throws {
        let task = S.task("T1", slug: "fix-login", created: S.date(10, 6))
        let live = S.thread("th1", task: "T1", created: S.date(10, 6))
        let shell = S.thread("th3", task: "T1", created: S.date(10, 6))
        let closed = HistoryEntry.threadClosed(S.thread("th2", task: "T1", created: S.date(10, 6)), at: S.date(10, 7))
        let result = ActivitySummary.build(period: S.week, timeZone: S.zone, scopes: [S.acme], tasks: [task],
                                           threads: [live, shell], history: [closed],
                                           tokens: ["th1": 1_000_000, "th2": 300_000])
        let rendered = try #require(result.scopes.first?.tasks.first)
        #expect(rendered.tokens == 1_300_000)
        #expect(rendered.threads.first { $0.id == "th3" }?.tokens == nil)
        #expect(result.limits.last == TokenUsageText.summaryLimit)
        #expect(CLIRenderer.text(.summary(result)).contains("1.3M tokens"))
    }

    @Test func noTranscriptMeansNoTokensAndNoNote() throws {
        let task = S.task("T1", slug: "fix-login", created: S.date(10, 6))
        let result = ActivitySummary.build(period: S.week, timeZone: S.zone, scopes: [S.acme], tasks: [task],
                                           threads: [S.thread("th1", task: "T1", created: S.date(10, 6))], history: [])
        #expect(result.scopes.first?.tasks.first?.tokens == nil)
        #expect(!result.limits.contains(TokenUsageText.summaryLimit))
    }

    @Test func theDetailOfATaskSaysItsTokens() throws {
        let task = S.task("T1", slug: "fix-login", created: S.date(10, 6))
        let result = try #require(ActivitySummary.detail(of: "fix-login", timeZone: S.zone, period: S.week, scopes: [S.acme],
                                                         tasks: [task], threads: [S.thread("th1", task: "T1", created: S.date(10, 6))],
                                                         history: [], tokens: ["th1": 42_000]))
        #expect(result.detail?.task.tokens == 42_000)
        #expect(CLIRenderer.text(.summary(result)).contains("tokens      42k"))
    }
}
