import Foundation
import ScopeAdapters
import ScopeCore
import Testing
@testable import ScopeDrivers

/// Hook payloads captured from Claude Code 2.1.301 in an interactive terminal, replayed through what the
/// `claude-hooks` adapter actually installs. Ids and paths are scrubbed; `tool_response` is cut short. Each run
/// had a hook on every event that only logged its stdin, so the logs also show the hooks Scope does not install.
struct ClaudePermissionReplayTests {
    /// Auto mode, `curl -sI https://example.com`: the terminal says "Allowed by auto mode classifier".
    static let classifierAllowed = [
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"auto","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"curl -sI https://example.com","description":"Fetch HTTP headers from example.com"},"tool_use_id":"toolu_1"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"auto","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"curl -sI https://example.com","description":"Fetch HTTP headers from example.com"},"tool_response":{"stdout":"HTTP/2 200","stderr":"","interrupted":false},"tool_use_id":"toolu_1","duration_ms":254}"#,
    ]

    /// Auto mode, an ask rule on the command and a second `PermissionRequest` hook answering allow at once (what a
    /// companion app does): the terminal says "Allowed by PermissionRequest hook", and nothing arrives until the
    /// tool has run, 15 s later.
    static let hookAllowed = [
        #"{"session_id":"s2","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"auto","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo scope-probe hello && sleep 15","description":"Echo probe message then sleep 15 seconds"},"tool_use_id":"toolu_2"}"#,
        #"{"session_id":"s2","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"auto","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo scope-probe hello && sleep 15","description":"Echo probe message then sleep 15 seconds"}}"#,
        #"{"session_id":"s2","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"auto","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo scope-probe hello && sleep 15","description":"Echo probe message then sleep 15 seconds"},"tool_response":{"stdout":"scope-probe hello","stderr":"","interrupted":false},"tool_use_id":"toolu_2","duration_ms":15223}"#,
    ]

    /// Auto mode, an ask rule on the command and nobody answering: the dialog stays up, and `permission_prompt`
    /// follows `PermissionRequest` six seconds later.
    static let promptShownInAuto = [
        #"{"session_id":"s3","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"auto","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo scope-probe hello","description":"Print scope-probe hello"},"tool_use_id":"toolu_3"}"#,
        #"{"session_id":"s3","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"auto","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo scope-probe hello","description":"Print scope-probe hello"}}"#,
        #"{"session_id":"s3","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#,
    ]

    /// `bypassPermissions`: an ordinary command runs unasked; one matching an ask rule still opens a dialog,
    /// which bypass does not skip.
    static let bypass = [
        #"{"session_id":"s4","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"python3 -c 'print(6*7)'","description":"Print 6 times 7 with Python"},"tool_use_id":"toolu_4"}"#,
        #"{"session_id":"s4","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"bypassPermissions","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"python3 -c 'print(6*7)'","description":"Print 6 times 7 with Python"},"tool_response":{"stdout":"42","stderr":"","interrupted":false},"tool_use_id":"toolu_4","duration_ms":240}"#,
        #"{"session_id":"s4","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo scope-probe hello","description":"Echo scope-probe hello"},"tool_use_id":"toolu_5"}"#,
        #"{"session_id":"s4","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"bypassPermissions","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo scope-probe hello","description":"Echo scope-probe hello"}}"#,
        #"{"session_id":"s4","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#,
    ]

    /// The thread state after each payload, starting from a running turn. A payload goes through the adapter's
    /// entry for its hook (matcher read as Claude Code does: an alternation over the tool name or the notification
    /// type), then `scope-hook`'s resolution, then the state machine.
    func replay(_ payloads: [String]) throws -> [ThreadState] {
        var state = ThreadState.running
        var states: [ThreadState] = []
        for payload in payloads {
            let data = Data(payload.utf8)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hook = try #require(object["hook_event_name"] as? String)
            let subject = (object["tool_name"] ?? object["notification_type"]) as? String
            let entry = ClaudeHooksAdapter.entries.first { entry in
                entry.event == hook
                    && (entry.matcher.map { $0.split(separator: "|").contains { $0 == subject ?? "" } } ?? true)
            }
            if let entry {
                let command = try #require(HookCommandEvent(word: entry.arguments[0]))
                let stdin = HookStdin.parse(data)
                if let kind = command.resolve(stdin: stdin) {
                    var fields: [String: String] = [:]
                    if command == .notification { fields[HookEvent.viaKey] = HookEvent.viaNotification }
                    if let tool = stdin.toolName { fields[HookEvent.toolKey] = tool }
                    state = ThreadStateMachine.next(state, on: AdapterEvent(threadID: ThreadID.generate(), kind: kind,
                                                                            payload: fields))
                }
            }
            states.append(state)
        }
        return states
    }

    @Test("a call auto mode's classifier allows never leaves running")
    func classifierAllowed() throws {
        #expect(try replay(Self.classifierAllowed) == [.running, .running])
    }

    @Test("a permission another hook answers never shows as waiting, however long the tool then runs")
    func hookAllowed() throws {
        #expect(try replay(Self.hookAllowed) == [.running, .running, .running])
    }

    @Test("a dialog left open waits from the permission_prompt notification, in auto mode too")
    func promptShownInAuto() throws {
        #expect(try replay(Self.promptShownInAuto) == [.running, .running, .waiting(reason: .permission)])
    }

    @Test("bypassPermissions only waits on a dialog it does not skip itself")
    func bypass() throws {
        #expect(try replay(Self.bypass) == [.running, .running, .running, .running, .waiting(reason: .permission)])
    }
}
