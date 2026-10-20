import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters
@testable import ScopeControl

@Suite("RateLimits")
struct RateLimitsTests {
    /// A status-line payload as Claude Code writes it (code.claude.com/docs/en/statusline), trimmed to what matters.
    static let statusline = #"""
    {"hook_event_name":"Status","session_id":"abc","cwd":"/w/repo","workspace":{"current_dir":"/w/repo/sub","project_dir":"/w/repo"},
     "model":{"id":"claude-fable-5-1","display_name":"Fable"},"context_window":{"used_percentage":12.5},
     "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
                    "seven_day":{"used_percentage":41.2,"resets_at":1738857600},
                    "seven_day_opus":{"used_percentage":67,"resets_at":1738857600},
                    "spend_limit":{"used_percentage":62.8,"resets_at":1740787200,"used_usd":314.12,"limit_usd":500,"period":"monthly"}}}
    """#

    static let now = Date(timeIntervalSince1970: 1738420000)

    @Test("the rate_limits object is lifted out of a status-line payload, compact, and parsed back")
    func extractsAndParses() throws {
        let data = Data(Self.statusline.utf8)
        let json = try #require(RateLimits.extract(statusline: data))
        #expect(!json.contains("\n"))
        #expect(json.hasPrefix("{\"five_hour\""))
        #expect(!json.contains("context_window"))

        let limits = try #require(RateLimits.parse(json, reportedAt: Self.now, thread: "3f9a2c17be04"))
        #expect(limits.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus", "spend_limit"])
        let five = limits.windows[0]
        #expect(five.usedPercentage == 23.5)
        #expect(five.resetsAt == Date(timeIntervalSince1970: 1738425600))
        #expect(five.label == "5-hour session")
        #expect(five.shortLabel == "5h")
        #expect(limits.windows[2].label == "Weekly · Opus")
        #expect(limits.windows[2].shortLabel == "7d Opus")
        let spend = limits.windows[3]
        #expect(spend.usedUSD == 314.12)
        #expect(spend.limitUSD == 500)
        #expect(spend.period == "monthly")
        #expect(limits.thread == "3f9a2c17be04")
        // The whole payload parses too, for whoever has it rather than the extracted object.
        #expect(RateLimits.parse(data, reportedAt: Self.now) == RateLimits(windows: limits.windows, reportedAt: Self.now))
    }

    @Test("a payload without rate_limits — an API key, or no answer yet — yields nothing, never a figure")
    func absentMeansUnknown() {
        #expect(RateLimits.extract(statusline: Data(#"{"model":{"id":"x"},"context_window":{"used_percentage":3}}"#.utf8)) == nil)
        #expect(RateLimits.extract(statusline: Data(#"{"rate_limits":{}}"#.utf8)) == nil)
        #expect(RateLimits.extract(statusline: Data("not json".utf8)) == nil)
        #expect(RateLimits.parse("{}", reportedAt: Self.now) == nil)
        #expect(RateLimits.parse(#"{"five_hour":{"resets_at":1738425600}}"#, reportedAt: Self.now) == nil)
        #expect(RateLimits.parse(#"{"five_hour":"soon"}"#, reportedAt: Self.now) == nil)
        #expect(HookStdin.parse(Data(#"{"session_id":"abc"}"#.utf8)).rateLimitsJSON == nil)
    }

    @Test("the statusline command sends limits.reported only when limits are in the payload")
    func statuslineCommandWord() throws {
        let command = try #require(HookCommandEvent(word: "statusline"))
        #expect(command == .statusline)
        #expect(command.needsStdin)
        #expect(HookCommandEvent.allWords.contains("statusline"))
        let with = HookStdin.parse(Data(Self.statusline.utf8))
        #expect(HookCommandEvent.statusline.resolve(stdin: with) == .limitsReported)
        #expect(with.projectDirectory == "/w/repo")
        let without = HookStdin.parse(Data(#"{"cwd":"/w","model":{"id":"x"}}"#.utf8))
        #expect(HookCommandEvent.statusline.resolve(stdin: without) == nil)
        #expect(without.projectDirectory == "/w")
        #expect(!HookEvent.Kind.limitsReported.changesState)
        #expect(HookEvent.Kind.limitsReported.stateEvent == nil)
    }

    @Test("the tightest window is the highest percentage, the earliest reset on a tie, and never one that has reset")
    func tightest() throws {
        let limits = try #require(RateLimits.parse(Self.statusline, reportedAt: Self.now))
        #expect(limits.tightest(now: Self.now)?.id == "seven_day_opus")
        // The 5-hour window has reset: it says nothing about the new one and is dropped, as Claude Code drops it.
        let afterFive = Date(timeIntervalSince1970: 1738425600)
        #expect(limits.current(now: afterFive).map(\.id) == ["seven_day", "seven_day_opus", "spend_limit"])
        // Tie on percentage: the one resetting first.
        let tie = RateLimits(windows: [
            .init(id: "seven_day", usedPercentage: 50, resetsAt: Self.now.addingTimeInterval(86_400)),
            .init(id: "five_hour", usedPercentage: 50, resetsAt: Self.now.addingTimeInterval(3_600)),
        ], reportedAt: Self.now)
        #expect(tie.tightest(now: Self.now)?.id == "five_hour")
        // Everything reset: nothing to show.
        let old = Date(timeIntervalSince1970: 1740787200)
        #expect(limits.tightest(now: old) == nil)
        #expect(limits.current(now: old).isEmpty)
    }

    @Test("levels split at half, four fifths and the ceiling")
    func levels() {
        #expect(RateLimitLevel(percentage: 0) == .calm)
        #expect(RateLimitLevel(percentage: 49.9) == .calm)
        #expect(RateLimitLevel(percentage: 50) == .watch)
        #expect(RateLimitLevel(percentage: 79.9) == .watch)
        #expect(RateLimitLevel(percentage: 80) == .tight)
        #expect(RateLimitLevel(percentage: 99.9) == .tight)
        #expect(RateLimitLevel(percentage: 100) == .exhausted)
        #expect(RateLimitLevel(percentage: 130) == .exhausted)
    }

    @Test("a report goes stale after thirty minutes without a newer one")
    func staleness() {
        let limits = RateLimits(windows: [.init(id: "five_hour", usedPercentage: 10)], reportedAt: Self.now)
        #expect(!limits.isStale(now: Self.now.addingTimeInterval(29 * 60)))
        #expect(limits.isStale(now: Self.now.addingTimeInterval(31 * 60)))
        #expect(limits.tightest(now: Self.now.addingTimeInterval(86_400 * 30))?.id == "five_hour", "no reset date keeps a window")
    }

    @Test("unknown windows are labelled from their key and sorted after the known ones")
    func unknownWindows() throws {
        let limits = try #require(RateLimits.parse(
            #"{"zeta_thing":{"used_percentage":1},"seven_day_sonnet":{"used_percentage":2},"five_hour":{"used_percentage":3},"alpha":{"used_percentage":4}}"#,
            reportedAt: Self.now))
        #expect(limits.windows.map(\.id) == ["five_hour", "seven_day_sonnet", "alpha", "zeta_thing"])
        #expect(RateLimitWindows.label(for: "seven_day_sonnet") == "Weekly · Sonnet")
        #expect(RateLimitWindows.label(for: "zeta_thing") == "Zeta Thing")
        #expect(RateLimitWindows.shortLabel(for: "zeta_thing") == "zeta thing")
    }

    @Test("the store round-trips through <home>/limits.json and starts empty")
    func storeRoundTrip() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "scope-limits-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = RateLimitsStore(home: home)
        #expect(await store.load() == nil)
        let limits = try #require(RateLimits.parse(Self.statusline, reportedAt: Self.now, thread: "t"))
        await store.save(limits)
        #expect(store.url == home.appending(path: "limits.json"))
        let loaded = try #require(await store.load())
        #expect(loaded.windows == limits.windows)
        #expect(loaded.thread == "t")
        #expect(abs(loaded.reportedAt.timeIntervalSince(Self.now)) < 0.002)
    }

    // MARK: Text and the CLI/MCP summary

    @Test("percentages are whole, the time to a reset coarse")
    func text() {
        #expect(RateLimitText.percent(23.5) == "24%")
        #expect(RateLimitText.percent(0) == "0%")
        #expect(RateLimitText.percent(100) == "100%")
        #expect(RateLimitText.percent(104) == ">100%")
        #expect(RateLimitText.remaining(until: Self.now.addingTimeInterval(35 * 60), now: Self.now) == "35 min")
        #expect(RateLimitText.remaining(until: Self.now.addingTimeInterval(2 * 3600 + 5 * 60), now: Self.now) == "2 h 05")
        #expect(RateLimitText.remaining(until: Self.now.addingTimeInterval(3 * 86_400 + 4 * 3600), now: Self.now) == "3 d 4 h")
        #expect(RateLimitText.remaining(until: Self.now.addingTimeInterval(2 * 86_400), now: Self.now) == "2 d")
        #expect(RateLimitText.remaining(until: Self.now.addingTimeInterval(10), now: Self.now) == "now")
        #expect(RateLimitText.remaining(until: Self.now.addingTimeInterval(-500), now: Self.now) == "now")
        let window = RateLimits.Window(id: "five_hour", usedPercentage: 31, resetsAt: Self.now.addingTimeInterval(35 * 60))
        #expect(RateLimitText.headline(window, now: Self.now) == "31% · 35 min")
        #expect(RateLimitText.reset(window, now: Self.now) == "resets in 35 min")
        #expect(RateLimitText.headline(.init(id: "x", usedPercentage: 5), now: Self.now) == "5%")
        #expect(RateLimitText.age(Self.now.addingTimeInterval(-30), now: Self.now) == "just now")
        #expect(RateLimitText.age(Self.now.addingTimeInterval(-12 * 60), now: Self.now) == "12 min ago")
    }

    @Test("the summary for agents names the tightest window, orders by percentage, and is nil when unknown")
    func summary() throws {
        let limits = try #require(RateLimits.parse(Self.statusline, reportedAt: Self.now))
        let summary = try #require(RateLimitsSummary(limits, plan: "Max 20×", now: Self.now))
        #expect(summary.tightest == "seven_day_opus")
        #expect(summary.windows.map(\.id) == ["seven_day_opus", "spend_limit", "seven_day", "five_hour"])
        #expect(summary.windows[0].level == "watch")
        #expect(summary.windows[3].resetsIn == 5600)
        #expect(summary.plan == "Max 20×")
        #expect(!summary.stale)
        #expect(RateLimitsSummary(nil, plan: nil, now: Self.now) == nil)
        #expect(RateLimitsSummary(limits, plan: nil, now: Date(timeIntervalSince1970: 1740787200)) == nil)

        let line = RateLimitText.line(summary, now: Self.now)
        #expect(line.hasPrefix("Max 20× — 7d Opus 67% (resets in 5 d"))
        #expect(line.contains("5h 24% (resets in 1 h 33)"))
        #expect(!line.contains("reported"))
        let stale = try #require(RateLimitsSummary(limits, plan: nil, now: Self.now.addingTimeInterval(3600)))
        #expect(stale.stale)
        #expect(RateLimitText.line(stale, now: Self.now.addingTimeInterval(3600)).hasSuffix("· reported 1 h 00 ago"))
    }

    @Test("ping and list carry the limits, and still decode without them")
    func protocolCarriesLimits() throws {
        let limits = try #require(RateLimits.parse(Self.statusline, reportedAt: Self.now))
        let summary = RateLimitsSummary(limits, plan: nil, now: Self.now)
        let ping = PingResult(app: "Scope", version: "1", home: "/h", automation: AutomationSettings(), limits: summary)
        let encoder = ControlProtocol.makeEncoder()
        let decoder = ControlProtocol.makeDecoder()
        let decoded = try decoder.decode(PingResult.self, from: encoder.encode(ping))
        #expect(decoded.limits?.tightest == "seven_day_opus")
        let text = CLIRenderer.text(.ping(ping))
        #expect(text.contains("limits      "))
        #expect(text.contains("7d Opus 67%"))
        #expect(CLIRenderer.text(.ping(PingResult(app: "Scope", version: "1", home: "/h", automation: AutomationSettings())))
            .contains("limits      unknown"))

        let old = try decoder.decode(PingResult.self, from: Data(#"{"app":"Scope","version":"1","home":"/h","rpc":1,"methods":[],"automation":{}}"#.utf8))
        #expect(old.limits == nil)
        let list = CLIRenderer.text(.list(ListResult(limits: summary)))
        #expect(list.hasPrefix("limits  "))
        #expect(CLIRenderer.text(.list(ListResult())) == "nothing yet")
    }
}

@Suite("ClaudeAccount")
struct ClaudeAccountTests {
    @Test("the plan is read from oauthAccount's tier, else its organization type")
    func parsesPlan() throws {
        let max = try #require(ClaudeAccount.parse(Data(#"{"oauthAccount":{"organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x","billingType":"stripe_subscription","userRateLimitTier":null}}"#.utf8)))
        #expect(max.planLabel == "Max 20×")
        #expect(max.isSubscription)
        #expect(ClaudeAccount(rateLimitTier: "default_claude_max_5x").planLabel == "Max 5×")
        #expect(ClaudeAccount(rateLimitTier: "default_claude_max").planLabel == "Max")
        #expect(ClaudeAccount(rateLimitTier: "default_claude_pro").planLabel == "Pro")
        #expect(ClaudeAccount(organizationType: "claude_pro").planLabel == "Pro")
        #expect(ClaudeAccount(organizationType: "claude_team").planLabel == "Team")
        #expect(ClaudeAccount(organizationType: "claude_enterprise").planLabel == "Enterprise")
        #expect(ClaudeAccount(organizationType: "claude_something_new").planLabel == "Something New")
        // A user tier set for the person outranks the organization's.
        let user = try #require(ClaudeAccount.parse(Data(#"{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_20x","userRateLimitTier":"default_claude_max_5x"}}"#.utf8)))
        #expect(user.planLabel == "Max 5×")
    }

    @Test("an API or console account is not a subscription, and no account is unknown")
    func apiAccount() {
        let api = ClaudeAccount(organizationType: "api", rateLimitTier: nil, billingType: "prepaid")
        #expect(!api.isSubscription)
        #expect(api.planLabel == nil)
        #expect(ClaudeAccount.parse(Data(#"{"numStartups":3}"#.utf8)) == nil)
        #expect(ClaudeAccount.parse(Data("{".utf8)) == nil)
    }

    @Test("the file follows CLAUDE_CONFIG_DIR")
    func fileLocation() {
        let home = URL(fileURLWithPath: "/Users/jane", isDirectory: true)
        #expect(ClaudeAccount.fileURL(environment: [:], home: home).path == "/Users/jane/.claude.json")
        #expect(ClaudeAccount.fileURL(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home).path == "/cfg/.claude.json")
    }
}

@Suite("ClaudeStatusline")
struct ClaudeStatuslineTests {
    @Test("the files that could have set a status line, in Claude Code's order of precedence")
    func settingsFiles() {
        let config = URL(fileURLWithPath: "/Users/jane/.claude", isDirectory: true)
        #expect(ClaudeStatusline.settingsFiles(projectDirectory: "/w/repo", configDirectory: config).map(\.path)
                == ["/w/repo/.claude/settings.local.json", "/w/repo/.claude/settings.json", "/Users/jane/.claude/settings.json"])
        #expect(ClaudeStatusline.settingsFiles(projectDirectory: nil, configDirectory: config).map(\.path)
                == ["/Users/jane/.claude/settings.json"])
        #expect(ClaudeStatusline.settingsFiles(projectDirectory: "relative", configDirectory: config).count == 1)
        #expect(ClaudeStatusline.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "/cfg"]).path == "/cfg")
        #expect(ClaudeStatusline.configDirectory(environment: [:], home: URL(fileURLWithPath: "/Users/jane")).path == "/Users/jane/.claude")
    }

    @Test("the first file that sets a command wins; a missing file or one without a status line is skipped")
    func userCommand() {
        let user = #"{"statusLine":{"type":"command","command":"sh ~/.claude/statusline-command.sh","padding":0}}"#
        let project = #"{"permissions":{}}"#
        let files = [URL(fileURLWithPath: "/p/.claude/settings.local.json"), URL(fileURLWithPath: "/p/.claude/settings.json"),
                     URL(fileURLWithPath: "/u/.claude/settings.json")]
        let contents = [files[1].path: project, files[2].path: user]
        let command = ClaudeStatusline.userCommand(files: files) { contents[$0.path].map { Data($0.utf8) } }
        #expect(command == .init(command: "sh ~/.claude/statusline-command.sh", padding: 0))
        #expect(ClaudeStatusline.userCommand(files: files) { _ in nil } == nil)
        #expect(ClaudeStatusline.command(in: Data(#"{"statusLine":{"type":"other","command":"x"}}"#.utf8)) == nil)
        #expect(ClaudeStatusline.command(in: Data(#"{"statusLine":{"command":"  "}}"#.utf8)) == nil)
        #expect(ClaudeStatusline.command(in: Data(#"{"statusLine":{"command":"echo hi"}}"#.utf8))?.command == "echo hi")
    }

    @Test("a nested run — the user's command calling back — runs nothing further")
    func nesting() {
        #expect(!ClaudeStatusline.isNested(environment: [:]))
        #expect(!ClaudeStatusline.isNested(environment: [ClaudeStatusline.nestedVariable: ""]))
        #expect(ClaudeStatusline.isNested(environment: [ClaudeStatusline.nestedVariable: "1"]))
    }
}
