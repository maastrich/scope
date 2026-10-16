import Foundation
import ScopeCore
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

    @Test("MessageDisplay gives the lines just written, their message and whether it is complete")
    func parsesMessageDisplay() {
        let json = #"{"session_id":"abc","hook_event_name":"MessageDisplay","turn_id":"t1","message_id":"m7","index":2,"final":false,"delta":"Two lines\nso far\n"}"#
        let stdin = HookStdin.parse(Data(json.utf8))
        #expect(stdin.displayDelta == "Two lines\nso far\n")
        #expect(stdin.displayMessageID == "m7")
        #expect(stdin.displayFinal == false)
        // The same keys on another hook mean nothing: `delta` is `MessageDisplay`'s word.
        let other = HookStdin.parse(Data(#"{"hook_event_name":"PostToolUse","delta":"x","message_id":"m"}"#.utf8))
        #expect(other.displayDelta == nil)
        #expect(other.displayMessageID == nil)
    }

    @Test("Codex notify payloads give their thread-id as the session id")
    func parsesCodexPayload() {
        let json = #"{"type":"agent-turn-complete","thread-id":"019","turn-id":"1","last-assistant-message":"done"}"#
        let stdin = HookStdin.parse(Data(json.utf8))
        #expect(stdin.sessionID == "019")
        #expect(stdin.hookEventName == "agent-turn-complete")
        #expect(stdin.notificationType == nil)
    }

    @Test("tool_name and StopFailure's error are lifted")
    func parsesToolNameAndError() {
        let tool = HookStdin.parse(Data(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#.utf8))
        #expect(tool.toolName == "AskUserQuestion")
        let failure = HookStdin.parse(Data(#"{"session_id":"s","hook_event_name":"StopFailure","error":"rate_limit"}"#.utf8))
        #expect(failure.error == "rate_limit")
    }

    @Test("the question is lifted from AskUserQuestion, ExitPlanMode and non-stock notifications")
    func parsesQuestion() {
        let ask = #"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which DB?","header":"DB","options":[]},{"question":"Migrate now?"}]}}"#
        #expect(HookStdin.parse(Data(ask.utf8)).question == "Which DB?\nMigrate now?")
        let plan = ##"{"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"# Plan\n1. do it"}}"##
        #expect(HookStdin.parse(Data(plan.utf8)).question == "# Plan\n1. do it")
        let elicitation = #"{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"Pick a Jira project"}"#
        #expect(HookStdin.parse(Data(elicitation.utf8)).question == "Pick a Jira project")
        let stock = #"{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#
        #expect(HookStdin.parse(Data(stock.utf8)).question == nil)
        let empty = #"{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"  "}]}}"#
        #expect(HookStdin.parse(Data(empty.utf8)).question == nil)
    }

    @Test("a permission request for a question tool is a question")
    func questionToolPermission() {
        let permission = HookCommandEvent.fixed(.permissionRequested)
        #expect(permission.resolve(stdin: HookStdin(toolName: "AskUserQuestion")) == .inputRequested)
        #expect(permission.resolve(stdin: HookStdin(toolName: "ExitPlanMode")) == .inputRequested)
        #expect(permission.resolve(stdin: HookStdin(toolName: "Bash")) == .permissionRequested)
        #expect(permission.resolve(stdin: HookStdin()) == .permissionRequested)
        #expect(ClaudeQuestionTools.matcher == "AskUserQuestion|ExitPlanMode")
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
        // Sent a minute after any unanswered reply: the turn is done, nobody is being asked anything.
        #expect(ClaudeNotificationMapping.kind(for: "idle_prompt") == nil)
        #expect(!ClaudeNotificationMapping.matcher.split(separator: "|").contains("idle_prompt"))
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
            #expect(parsed?.resolve(stdin: HookStdin(toolName: "Bash")) == kind)
        }
        let notification = HookCommandEvent(word: "notification")
        #expect(notification == .notification)
        #expect(notification?.needsStdin == true)
        #expect(notification?.resolve(stdin: HookStdin(notificationType: "permission_prompt")) == .permissionRequested)
        #expect(notification?.resolve(stdin: HookStdin(notificationType: "idle_prompt")) == nil)
        #expect(notification?.resolve(stdin: HookStdin(notificationType: "auth_success")) == nil)
        #expect(HookCommandEvent(word: "Notification") == nil)
        #expect(HookCommandEvent(word: "turn.paused") == nil)
        #expect(HookCommandEvent.allWords.count == HookEvent.Kind.allCases.count + 1)
    }

    @Test("the folder of the file a tool touched says where the driver works; cwd is the fallback")
    func liftsTheWorkingDirectory() {
        let edit = HookStdin.parse(Data(#"{"hook_event_name":"PostToolUse","cwd":"/sandbox/task","tool_name":"Edit","tool_input":{"file_path":"/sandbox/task/web/src/auth.ts"}}"#.utf8))
        #expect(edit.directory == "/sandbox/task/web/src")
        let bash = HookStdin.parse(Data(#"{"hook_event_name":"PostToolUse","cwd":"/sandbox/task","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8))
        #expect(bash.directory == "/sandbox/task")
        let relative = HookStdin.parse(Data(#"{"cwd":"/sandbox/task","tool_input":{"file_path":"web/a.ts"}}"#.utf8))
        #expect(relative.directory == "/sandbox/task")
        #expect(HookStdin.parse(Data(#"{"session_id":"s"}"#.utf8)).directory == nil)
    }

    @Test("the agent's last answer is lifted from Claude Code's Stop and Codex notify")
    func lastAssistantMessage() {
        let claude = HookStdin.parse(Data(#"{"hook_event_name":"Stop","last_assistant_message":"All green."}"#.utf8))
        #expect(claude.lastAssistantMessage == "All green.")
        let codex = HookStdin.parse(Data(#"{"type":"agent-turn-complete","last-assistant-message":"Done."}"#.utf8))
        #expect(codex.lastAssistantMessage == "Done.")
        #expect(HookStdin.parse(Data(#"{"last_assistant_message":"  "}"#.utf8)).lastAssistantMessage == nil)
    }

    @Test("only the end of a turn carries a reply; a truncated stdin carries it in the payload")
    func agentReplyFromEvents() throws {
        let thread = try #require(ThreadID(rawValue: "3f9a2c17be04"))
        let at = Date(timeIntervalSince1970: 5)
        let raw = #"{"last_assistant_message":"All green."}"#
        #expect(AgentReply.from(AdapterEvent(threadID: thread, kind: .turnEnded, raw: raw, receivedAt: at))
                == AgentReply(text: "All green.", at: at))
        #expect(AgentReply.from(AdapterEvent(threadID: thread, kind: .turnStarted, raw: raw)) == nil)
        let cut = AdapterEvent(threadID: thread, kind: .turnEnded, payload: [HookEvent.replyKey: "Long answer."],
                               raw: #"{"last_assistant_message":"Long ans"#, receivedAt: at)
        #expect(AgentReply.from(cut)?.text == "Long answer.")
        #expect(AgentReply.from(AdapterEvent(threadID: thread, kind: .turnEnded)) == nil)
    }

    @Test("Codex notify hands its JSON as an argument, which is told apart from key=value")
    func inlinePayload() {
        #expect(HookStdin.isInlinePayload(#"{"type":"agent-turn-complete"}"#))
        #expect(HookStdin.isInlinePayload("  {}"))
        #expect(!HookStdin.isInlinePayload("session_id={x}"))
        #expect(!HookStdin.isInlinePayload("turn.ended"))
    }
    /// `PostToolUse` stdin as Claude Code sends it, for `tool` with `input` (and a response, which is what grows).
    static func postToolUse(_ tool: String, _ input: String, response: String = #"{"success":true}"#) -> Data {
        Data(#"""
        {"session_id":"9b1d","transcript_path":"/Users/me/.claude/projects/-w/9b1d.jsonl","cwd":"/w",\#
        "permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"\#(tool)",\#
        "tool_input":\#(input),"tool_response":\#(response),"tool_use_id":"toolu_01"}
        """#.utf8)
    }

    @Test("each tool kind gives the one thing it was about", arguments: [
        ("Read", #"{"file_path":"/w/Sources/App.swift"}"#, "/w/Sources/App.swift"),
        ("Edit", #"{"file_path":"/w/a.swift","old_string":"x","new_string":"y","replace_all":false}"#, "/w/a.swift"),
        ("Write", #"{"file_path":"/w/new.md","content":"Title\nbody"}"#, "/w/new.md"),
        ("MultiEdit", #"{"file_path":"/w/b.swift","edits":[{"old_string":"a","new_string":"b"}]}"#, "/w/b.swift"),
        ("NotebookEdit", #"{"notebook_path":"/w/n.ipynb","new_source":"print(1)"}"#, "/w/n.ipynb"),
        ("Bash", #"{"command":"\n  swift test --filter SlugTests\nswift build","description":"Run the suite"}"#,
         "swift test --filter SlugTests"),
        ("Grep", #"{"pattern":"ThreadActivity","path":"/w/Sources","output_mode":"files_with_matches"}"#, "ThreadActivity"),
        ("Glob", #"{"pattern":"**/*.swift","path":"/w"}"#, "**/*.swift"),
        ("WebFetch", #"{"url":"https://code.claude.com/docs/en/hooks","prompt":"List the events"}"#,
         "https://code.claude.com/docs/en/hooks"),
        ("WebSearch", #"{"query":"swift testing arguments"}"#, "swift testing arguments"),
        ("Task", #"{"description":"Survey the hooks","prompt":"Read every file…","subagent_type":"Explore"}"#,
         "Survey the hooks"),
        ("Agent", #"{"description":"Review the diff","prompt":"…"}"#, "Review the diff"),
        ("mcp__scope__scope_thread_wait", #"{"threads":["3f9a"],"thread":"3f9a"}"#, "3f9a"),
        ("AskUserQuestion", #"{"questions":[{"question":"Which suite first?","header":"Suite","options":[]},{"question":"Then?"}]}"#,
         "Which suite first?"),
        ("ExitPlanMode", #"{"plan":"Plan: rename\n1. Read"}"#, "Plan: rename"),
    ])
    func toolTargets(tool: String, input: String, target: String) {
        let stdin = HookStdin.parse(Self.postToolUse(tool, input))
        #expect(stdin.toolName == tool)
        #expect(stdin.toolTarget == target)
        #expect(stdin.transcriptPath == "/Users/me/.claude/projects/-w/9b1d.jsonl")
    }

    @Test("a long command is cut to its first line and to the limit")
    func longCommand() {
        let command = String(repeating: "x", count: 500)
        let stdin = HookStdin.parse(Self.postToolUse("Bash", #"{"command":"\#(command)\necho done"}"#))
        let target = stdin.toolTarget ?? ""
        #expect(target.count == HookStdin.toolTargetLimit)
        #expect(target.hasSuffix("…"))
        #expect(!target.contains("echo"))
    }

    @Test("a missing, empty or odd tool_input gives no target and fails nothing")
    func missingToolInput() {
        #expect(HookStdin.parse(Data(#"{"hook_event_name":"PostToolUse","tool_name":"Read"}"#.utf8)).toolTarget == nil)
        #expect(HookStdin.parse(Self.postToolUse("Read", "{}")).toolTarget == nil)
        #expect(HookStdin.parse(Self.postToolUse("Read", #""not an object""#)).toolTarget == nil)
        #expect(HookStdin.parse(Self.postToolUse("Bash", #"{"command":"  \n "}"#)).toolTarget == nil)
        #expect(HookStdin.parse(Self.postToolUse("Read", #"{"file_path":42}"#)).toolTarget == nil)
        #expect(HookStdin.parse(Data(#"{"transcript_path":""}"#.utf8)).transcriptPath == nil)
    }

    /// The stdin is parsed before `scope-hook` cuts it: a huge tool response still gives its target, while the cut
    /// `raw` no longer parses at all — which is why the target travels in the payload.
    @Test("the target survives a stdin too large to forward whole")
    func truncatedPayload() {
        let response = #"{"file":{"content":""# + String(repeating: "a", count: 300 * 1024) + #""}}"#
        let data = Self.postToolUse("Read", #"{"file_path":"/w/huge.log"}"#, response: response)
        #expect(HookStdin.parse(data).toolTarget == "/w/huge.log")
        #expect(HookStdin.parse(data.prefix(256 * 1024)) == HookStdin())
    }
}
