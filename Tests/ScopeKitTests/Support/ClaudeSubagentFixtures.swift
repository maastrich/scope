/// Hook payloads and files of a real Claude Code 2.1.304 session that launched one background and one foreground
/// sub-agent, anonymized like `ClaudeNativeFixtures`: every free text, path and id replaced by a placeholder, then
/// given the ids, times and figures the tests need. Keys, nesting and enum values are as Claude Code wrote them.
enum ClaudeSubagentFixtures {
    // MARK: Hooks (stdin)

    static let postToolUseAsync = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","permission_mode":"bypassPermissions","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"<text>","prompt":"<text>","subagent_type":"general-purpose","model":"haiku","run_in_background":true},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"a0000000000000001","description":"<text>","resolvedModel":"claude-haiku-5-5","prompt":"<text>","outputFile":"<path>","canReadOutputFile":true,"canContinueAgent":true},"tool_use_id":"toolu_agent1","duration_ms":12}"#
    static let subagentStart = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","agent_id":"a0000000000000001","agent_type":"general-purpose","hook_event_name":"SubagentStart"}"#
    static let subagentStop = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","permission_mode":"bypassPermissions","agent_id":"a0000000000000001","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"/p/session/subagents/agent-a0000000000000001.jsonl","last_assistant_message":"<last message>","background_tasks":[{"id":"a0000000000000001","type":"subagent","status":"running","description":"<text>","agent_type":"general-purpose"}],"session_crons":[]}"#
    /// One of Claude Code's own agents: an empty `agent_type`.
    static let internalSubagentStop = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","agent_id":"a0000000000000009","agent_type":"","hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"<path>","last_assistant_message":"<text>","background_tasks":[],"session_crons":[]}"#
    static let syncSubagentStart = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","agent_id":"a0000000000000002","agent_type":"general-purpose","hook_event_name":"SubagentStart"}"#
    static let syncSubagentStop = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","permission_mode":"bypassPermissions","agent_id":"a0000000000000002","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"SubagentStop","stop_hook_active":false,"agent_transcript_path":"<path>","last_assistant_message":"<sync last message>","background_tasks":[],"session_crons":[]}"#
    static let postToolUseSync = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","permission_mode":"bypassPermissions","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"<sync text>","prompt":"<text>","subagent_type":"general-purpose","model":"haiku","run_in_background":false},"tool_response":{"status":"completed","prompt":"<text>","agentId":"a0000000000000002","agentType":"general-purpose","harnessNoteCount":0,"harnessTailCount":0,"harnessSectionHash":"<id>","content":[{"type":"text","text":"<sync result>"}],"resolvedModel":"claude-haiku-5-5","totalDurationMs":1612,"totalTokens":27599,"totalToolUseCount":0,"usage":{"input_tokens":2,"cache_creation_input_tokens":27594,"cache_read_input_tokens":0,"output_tokens":3},"canContinueAgent":true},"tool_use_id":"toolu_agent2","duration_ms":1700}"#
    /// A sub-agent's own tool call: its `agent_id` and `agent_type` on an ordinary `PostToolUse`.
    static let postToolUseInsideAgent = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","permission_mode":"bypassPermissions","agent_id":"a0000000000000001","agent_type":"general-purpose","effort":{"level":"medium"},"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"<command>","description":"<text>"},"tool_response":{"interrupted":false,"isImage":false,"noOutputExpected":false,"stderr":"","stdout":"<text>"},"tool_use_id":"toolu_inner","duration_ms":40}"#
    static func sessionStart(_ source: String) -> String {
        #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","hook_event_name":"SessionStart","source":"\#(source)"}"#
    }
    static let sessionEnd = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"<path>","prompt_id":"<id>","hook_event_name":"SessionEnd","reason":"other"}"#

    // MARK: Files

    static let meta = #"{"agentType":"general-purpose","description":"<text>","toolUseId":"toolu_agent1","spawnDepth":1,"requestShape":"background","requestNonInteractive":true,"model":"haiku","finished":true}"#
    static let metaWorktree = #"{"agentType":"general-purpose","description":"<text>","toolUseId":"toolu_agent3","spawnDepth":2,"requestShape":"foreground","requestNonInteractive":true,"launchedWithDefaults":true,"worktreePath":"<path>","spawnedWithWorktree":true,"worktreeBranch":"<branch>"}"#
    /// A sub-agent's own transcript: an assistant line with one tool call, then its result.
    static func subagentToolUse(_ id: String, tool: String = "Bash", command: String = "<command>") -> String {
        #"{"parentUuid":"<id>","isSidechain":true,"agentId":"a0000000000000001","type":"assistant","uuid":"<id>","timestamp":"2026-10-20T10:00:10.000Z","message":{"role":"assistant","model":"claude-haiku-5-5","id":"<id>","content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":{"command":"\#(command)","description":"<text>"}}]}}"#
    }
    static let subagentToolResult = #"{"parentUuid":"<id>","isSidechain":true,"agentId":"a0000000000000001","type":"user","uuid":"<id>","timestamp":"2026-10-20T10:00:11.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_inner","type":"tool_result","content":"<text>","is_error":false}]}}"#

    /// A background sub-agent stopped by the agent, without usage.
    static let agentKilled = #"{"parentUuid":"<id>","isSidechain":false,"promptId":"<id>","type":"user","message":{"role":"user","content":"<task-notification>\n<task-id>a0000000000000004</task-id>\n<tool-use-id>toolu_agent4</tool-use-id>\n<output-file><path></output-file>\n<status>killed</status>\n<summary>Agent \"<text>\" was stopped</summary>\n</task-notification>"},"uuid":"<id>","timestamp":"2026-10-20T10:06:00.000Z","origin":{"kind":"task-notification"},"sessionId":"<id>","version":"2.1.304"}"#
}
