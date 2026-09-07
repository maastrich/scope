import Foundation
import Testing
@testable import ScopeAdapters

@Suite("HookStdin")
struct HookStdinTests {
    @Test("session_id, notification_type and hook_event_name are lifted from Claude Code's JSON")
    func parsesClaudeCodePayload() {
        let json = #"{"session_id":"abc","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}"#
        let stdin = HookStdin.parse(Data(json.utf8))
        #expect(stdin.sessionID == "abc")
        #expect(stdin.notificationType == "permission_prompt")
        #expect(stdin.hookEventName == "Notification")
    }

    @Test("Codex notify payloads give their thread-id as the session id")
    func parsesCodexPayload() {
        let json = #"{"type":"agent-turn-complete","thread-id":"019","turn-id":"1","last-assistant-message":"done"}"#
        let stdin = HookStdin.parse(Data(json.utf8))
        #expect(stdin.sessionID == "019")
        #expect(stdin.hookEventName == "agent-turn-complete")
        #expect(stdin.notificationType == nil)
    }

    @Test("empty, non-JSON or non-object stdin yields an empty value instead of failing")
    func tolerantParsing() {
        #expect(HookStdin.parse(Data()) == HookStdin())
        #expect(HookStdin.parse(Data("not json".utf8)) == HookStdin())
        #expect(HookStdin.parse(Data("[1,2]".utf8)) == HookStdin())
        #expect(HookStdin.parse(Data(#"{"session_id":""}"#.utf8)).sessionID == nil)
        #expect(HookStdin.parse(Data(#"{"session_id":42}"#.utf8)).sessionID == nil)
    }

    @Test(arguments: [
        ("permission_prompt", HookEvent.Kind.permissionRequested),
        ("idle_prompt", .inputRequested),
        ("agent_needs_input", .inputRequested),
        ("elicitation_dialog", .inputRequested),
    ])
    func notificationTypesThatNeedSomeone(type: String, kind: HookEvent.Kind) {
        #expect(ClaudeNotificationMapping.kind(for: type) == kind)
        #expect(ClaudeNotificationMapping.matcher.split(separator: "|").contains(Substring(type)))
    }

    @Test("informational notifications send nothing; a missing type is a plain input request")
    func informationalNotifications() {
        #expect(ClaudeNotificationMapping.kind(for: "auth_success") == nil)
        #expect(ClaudeNotificationMapping.kind(for: "agent_completed") == nil)
        #expect(ClaudeNotificationMapping.kind(for: "quota_auto_resume_fired") == nil)
        #expect(ClaudeNotificationMapping.kind(for: nil) == .inputRequested)
        #expect(ClaudeNotificationMapping.kind(for: "") == .inputRequested)
    }

    @Test("the command line accepts every wire event plus `notification`")
    func commandEvents() {
        for kind in HookEvent.Kind.allCases {
            let parsed = HookCommandEvent(word: kind.rawValue)
            #expect(parsed == .fixed(kind))
            #expect(parsed?.needsStdin == false)
            #expect(parsed?.resolve(stdin: HookStdin(notificationType: "auth_success")) == kind)
        }
        let notification = HookCommandEvent(word: "notification")
        #expect(notification == .notification)
        #expect(notification?.needsStdin == true)
        #expect(notification?.resolve(stdin: HookStdin(notificationType: "permission_prompt")) == .permissionRequested)
        #expect(notification?.resolve(stdin: HookStdin(notificationType: "idle_prompt")) == .inputRequested)
        #expect(notification?.resolve(stdin: HookStdin(notificationType: "auth_success")) == nil)
        #expect(HookCommandEvent(word: "Notification") == nil)
        #expect(HookCommandEvent(word: "turn.paused") == nil)
        #expect(HookCommandEvent.allWords.count == HookEvent.Kind.allCases.count + 1)
    }
}
