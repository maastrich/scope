/// Background work as Claude Code 2.1.299–2.1.304 wrote it, anonymized like `ClaudeNativeFixtures`: every free text,
/// path and id replaced by a placeholder, then given the ids, times and figures the tests need. The shapes — keys,
/// tags, the wording of summaries and events — are as observed in real transcripts and in a session driven for the
/// purpose (docs/research/claude-native.md §1.2–1.3).
enum ClaudeBackgroundFixtures {
    static func toolUse(_ id: String, _ name: String, input: String, at: String) -> String {
        #"{"type":"assistant","isSidechain":false,"uuid":"<id>","timestamp":"\#(at)","message":{"role":"assistant","model":"claude-opus-5-5","id":"<id>","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input),"caller":{"type":"direct"}}]}}"#
    }

    static func toolResult(_ id: String, content: String, result: String, at: String) -> String {
        #"{"parentUuid":"<id>","isSidechain":false,"promptId":"<id>","type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":"\#(content)","is_error":false}]},"uuid":"<id>","timestamp":"\#(at)","toolUseResult":\#(result),"sourceToolAssistantUUID":"<id>","userType":"external","entrypoint":"cli","cwd":"<path>","sessionId":"<id>","version":"2.1.304","gitBranch":"<branch>"}"#
    }

    static func notification(_ body: String, at: String) -> String {
        let escaped = body.replacingOccurrences(of: "\"", with: #"\""#).replacingOccurrences(of: "\n", with: #"\n"#)
        return #"{"parentUuid":"<id>","isSidechain":false,"promptId":"<id>","type":"user","message":{"role":"user","content":"<task-notification>\n\#(escaped)\n</task-notification>"},"uuid":"<id>","timestamp":"\#(at)","permissionMode":"bypassPermissions","origin":{"kind":"task-notification"},"userType":"external","entrypoint":"cli","cwd":"<path>","sessionId":"<id>","version":"2.1.304","gitBranch":"<branch>"}"#
    }

    // Bash, sent to the background on purpose.
    static let bashUse = toolUse("toolu_bg1", "Bash", input: #"{"command":"<command one>","description":"<text>","run_in_background":true}"#,
                                 at: "2026-10-20T10:00:00.000Z")
    static let bashLaunched = toolResult("toolu_bg1",
                                         content: "Command running in background with ID: b00000011. Output is being written to: <path> You will be notified when it completes — do not poll that file or sleep while waiting.",
                                         result: #"{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"b00000011"}"#,
                                         at: "2026-10-20T10:00:01.000Z")
    // Bash, moved to the background after its two-minute timeout.
    static let slowUse = toolUse("toolu_bg2", "Bash", input: #"{"command":"<command two>","description":"<text>","timeout":120000}"#,
                                 at: "2026-10-20T10:00:00.000Z")
    static let slowMoved = toolResult("toolu_bg2",
                                      content: "Command did not complete within its 120000ms timeout and was moved to the background (ID: b00000012). Output is being written to: <path>",
                                      result: #"{"stdout":"<text>","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"b00000012","timedOutAfterMs":120000,"backgroundCwdHint":"<text>"}"#,
                                      at: "2026-10-20T10:02:00.000Z")
    // Bash denied by a hook: an error string, no id.
    static let deniedUse = toolUse("toolu_bg3", "Bash", input: #"{"command":"<text>","run_in_background":true}"#, at: "2026-10-20T10:00:00.000Z")
    static let denied = #"{"parentUuid":"<id>","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_bg3","type":"tool_result","content":"Error: <text>","is_error":true}]},"uuid":"<id>","timestamp":"2026-10-20T10:00:01.000Z","toolUseResult":"Error: <text>"}"#

    static let completed = notification("""
        <task-id>b00000011</task-id>
        <tool-use-id>toolu_bg1</tool-use-id>
        <output-file>/tmp/claude-501/<project>/<session>/tasks/b00000011.output</output-file>
        <status>completed</status>
        <summary>Background command "<command one>" completed (exit code 0)</summary>
        """, at: "2026-10-20T10:05:00.000Z")
    static let failed = notification("""
        <task-id>b00000012</task-id>
        <tool-use-id>toolu_bg2</tool-use-id>
        <output-file><path></output-file>
        <status>failed</status>
        <summary>Background command "<command two> && echo "exit code 7"" failed with exit code 2</summary>
        """, at: "2026-10-20T10:06:00.000Z")
    static let killed = notification("""
        <task-id>b00000011</task-id>
        <tool-use-id>toolu_bg1</tool-use-id>
        <output-file><path></output-file>
        <status>killed</status>
        <summary>Background command "<command one>" was stopped</summary>
        """, at: "2026-10-20T10:04:00.000Z")
    // At a resume, for what the previous process left running: several ids in one notice.
    static let stoppedAtSessionEnd = notification("""
        <task-id>b00000011</task-id>
        <task-id>b00000012</task-id>
        <status>stopped</status>
        <summary>2 background shell command tasks didn't finish before the previous session ended. Task ids: b00000011, b00000012.</summary>
        <note><text></note>
        """, at: "2026-10-20T11:00:00.000Z")

    static let stopUse = toolUse("toolu_stop", "TaskStop", input: #"{"task_id":"b00000011"}"#, at: "2026-10-20T10:03:00.000Z")
    static let stopResult = toolResult("toolu_stop", content: "<text>",
                                       result: #"{"message":"Successfully stopped task: b00000011 (<command one>)","task_id":"b00000011","task_type":"local_bash","command":"<command one>"}"#,
                                       at: "2026-10-20T10:03:01.000Z")

    // A Monitor with a 2-minute deadline: two events, then one of three ends.
    static let monitorUse = toolUse("toolu_mon", "Monitor", input: #"{"command":"<command three>","description":"<text>","timeout_ms":120000}"#,
                                    at: "2026-10-20T10:00:00.000Z")
    static let monitorStarted = toolResult("toolu_mon",
                                           content: "Monitor started (task b00000013, expires in 2m unless the source ends first; you get one notice at expiry — re-arm if you still need the watch).",
                                           result: #"{"taskId":"b00000013","timeoutMs":120000,"persistent":false}"#, at: "2026-10-20T10:00:01.000Z")
    static func monitorEvent(_ text: String, at: String) -> String {
        notification("""
            <task-id>b00000013</task-id>
            <summary>Monitor event: "<text>"</summary>
            <event>\(text)</event>
            """, at: at)
    }
    static let monitorExpired = monitorEvent("[Monitor expired after 2m with 2 events delivered. Re-arm it if you still need the watch.]",
                                             at: "2026-10-20T10:02:01.000Z")
    static let monitorStreamEnded = notification("""
        <task-id>b00000013</task-id>
        <tool-use-id>toolu_mon</tool-use-id>
        <output-file><path></output-file>
        <status>completed</status>
        <summary>Monitor "<text>" stream ended</summary>
        <event><text></event>
        """, at: "2026-10-20T10:01:30.000Z")
    static let monitorScriptFailed = notification("""
        <task-id>b00000013</task-id>
        <tool-use-id>toolu_mon</tool-use-id>
        <output-file><path></output-file>
        <status>failed</status>
        <summary>Monitor "<text>" script failed (exit 144)</summary>
        """, at: "2026-10-20T10:01:30.000Z")

    // ScheduleWakeup and the crons, in the shapes their tool results take (the cron ones seen in a real session).
    static let wakeupUse = toolUse("toolu_wake", "ScheduleWakeup", input: #"{"delaySeconds":1200,"reason":"<text>","prompt":"<prompt>"}"#,
                                   at: "2026-10-20T10:00:00.000Z")
    static let wakeupSet = toolResult("toolu_wake", content: "<text>", result: #"{"scheduledFor":1792490400000,"stopped":false}"#,
                                      at: "2026-10-20T10:00:01.000Z")
    static let cronUse = toolUse("toolu_cron", "CronCreate", input: #"{"cron":"17 3 1 1 *","prompt":"<prompt>","recurring":false}"#,
                                 at: "2026-10-20T10:00:00.000Z")
    static let cronCreated = toolResult("toolu_cron", content: "<text>",
                                        result: #"{"id":"8840f90e","humanSchedule":"17 3 1 1 *","recurring":false,"durable":false,"nextFireAt":1798769820000}"#,
                                        at: "2026-10-20T10:00:01.000Z")
    static let cronDeleteUse = toolUse("toolu_crondel", "CronDelete", input: #"{"id":"8840f90e"}"#, at: "2026-10-20T10:10:00.000Z")
    static let cronDeleted = toolResult("toolu_crondel", content: "Cancelled job 8840f90e.", result: #"{"id":"8840f90e"}"#,
                                        at: "2026-10-20T10:10:01.000Z")

    // Hook payloads, as `scope-hook` forwards their stdin.
    static let postToolUseBash = #"{"hook_event_name":"PostToolUse","session_id":"<id>","transcript_path":"<path>","cwd":"<path>","permission_mode":"bypassPermissions","tool_name":"Bash","tool_use_id":"toolu_bg1","tool_input":{"command":"<command one>","description":"<text>","run_in_background":true},"tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"b00000011"},"duration_ms":40}"#
    static func stop(tasks: String, crons: String = "[]") -> String {
        #"{"hook_event_name":"Stop","session_id":"<id>","transcript_path":"<path>","cwd":"<path>","permission_mode":"bypassPermissions","stop_hook_active":false,"last_assistant_message":"<text>","background_tasks":\#(tasks),"session_crons":\#(crons)}"#
    }
    static let sessionEnd = #"{"hook_event_name":"SessionEnd","session_id":"<id>","transcript_path":"<path>","cwd":"<path>","reason":"prompt_input_exit"}"#
}
