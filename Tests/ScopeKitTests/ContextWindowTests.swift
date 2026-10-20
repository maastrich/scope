import Foundation
import ScopeCore
import Testing
@testable import ScopeAdapters

@Suite("ContextWindow")
struct ContextWindowTests {
    static let statusline = #"""
    {"hook_event_name":"Status","session_id":"abc","cwd":"/w/repo","version":"2.1.47",
     "model":{"id":"claude-fable-5-1","display_name":"Fable 5.1"},
     "context_window":{"total_input_tokens":184000,"total_output_tokens":22000,"context_window_size":200000,"used_percentage":38.4,"remaining_percentage":61.6},
     "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600}}}
    """#
    static let now = Date(timeIntervalSince1970: 1738420000)

    @Test("the context window, the model and the version are lifted out of a status-line payload and parsed back")
    func extractsAndParses() throws {
        let json = try #require(ContextWindowReport.extract(statusline: Data(Self.statusline.utf8)))
        #expect(!json.contains("\n"))
        #expect(!json.contains("rate_limits"))
        #expect(!json.contains("remaining_percentage"))
        let report = try #require(ContextWindowReport.parse(json, reportedAt: Self.now))
        #expect(report.usedPercentage == 38.4)
        #expect(report.windowSize == 200_000)
        #expect(report.modelID == "claude-fable-5-1")
        #expect(report.modelName == "Fable 5.1")
        #expect(report.driverVersion == "2.1.47")
        #expect(report.reportedAt == Self.now)
        #expect(report.percentageText == "38 %")
        #expect(report.fraction == 0.384)
    }

    @Test("a payload that names a model but no window still reports the model, and nothing reports nothing")
    func partialPayloads() throws {
        let modelOnly = try #require(ContextWindowReport.extract(statusline: Data(#"{"model":{"id":"x","display_name":"X"}}"#.utf8)))
        let report = try #require(ContextWindowReport.parse(modelOnly, reportedAt: Self.now))
        #expect(report.usedPercentage == nil)
        #expect(report.percentageText == nil)
        #expect(report.modelName == "X")
        #expect(ContextWindowReport.extract(statusline: Data(#"{"cwd":"/w"}"#.utf8)) == nil)
        #expect(ContextWindowReport.extract(statusline: Data("not json".utf8)) == nil)
        #expect(ContextWindowReport.parse("{}", reportedAt: Self.now) == nil)
        #expect(ContextWindowReport.parse(#"{"used_percentage":140}"#, reportedAt: Self.now)?.fraction == 1)
    }

    @Test("the statusline command sends limits.reported for a context window alone, with both objects in the payload")
    func statuslineCarriesBoth() {
        let both = HookStdin.parse(Data(Self.statusline.utf8))
        #expect(both.rateLimitsJSON != nil)
        #expect(both.contextWindowJSON != nil)
        #expect(HookCommandEvent.statusline.resolve(stdin: both) == .limitsReported)
        let windowOnly = HookStdin.parse(Data(#"{"context_window":{"used_percentage":3}}"#.utf8))
        #expect(windowOnly.rateLimitsJSON == nil)
        #expect(HookCommandEvent.statusline.resolve(stdin: windowOnly) == .limitsReported)
        let neither = HookStdin.parse(Data(#"{"cwd":"/w"}"#.utf8))
        #expect(HookCommandEvent.statusline.resolve(stdin: neither) == nil)
    }

    @Test("the activity keeps the last report, through a restart, and a thread that never reported has none")
    func activityKeepsTheReport() throws {
        let json = try #require(ContextWindowReport.extract(statusline: Data(Self.statusline.utf8)))
        let event = AdapterEvent(threadID: ThreadID(rawValue: "3f9a2c17be04")!, kind: .limitsReported,
                                 payload: [HookEvent.contextKey: json], receivedAt: Self.now)
        let activity = ThreadActivity().apply(event)
        #expect(activity.contextWindow?.usedPercentage == 38.4)
        #expect(!activity.inTurn)
        // A limits-only report changes nothing of the window.
        let limitsOnly = AdapterEvent(threadID: ThreadID(rawValue: "3f9a2c17be04")!, kind: .limitsReported,
                                      payload: [HookEvent.limitsKey: "{}"], receivedAt: Self.now)
        #expect(activity.apply(limitsOnly).contextWindow?.usedPercentage == 38.4)
        // Saved and read back under a fresh activity: the report comes along.
        let data = try JSONEncoder().encode(activity)
        let saved = try JSONDecoder().decode(ThreadActivity.self, from: data)
        #expect(ThreadActivity().restoring(saved).contextWindow?.modelName == "Fable 5.1")
        #expect(ThreadActivity().contextWindow == nil)
    }
}
