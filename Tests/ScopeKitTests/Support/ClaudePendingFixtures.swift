/// Hook payloads captured from Claude Code 2.1.304 in an interactive terminal (default permission mode, an ask rule on
/// `echo probe`, and a two-tool stdio MCP server written for the probe), one sequence per dialog. Ids shortened, paths
/// replaced by `/w`, `prompt` by `<text>`; `scratchpad_dir`, `prompt_id`, `effort` and the `Stop` extras dropped.
/// Every hook was logged, so a sequence also holds the ones Scope does not install (`PreToolUse` of other tools):
/// `ClaudePendingRequestsTests.replay` keeps only those it does.
enum ClaudePendingFixtures {
    static let prompt = #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"UserPromptSubmit","prompt":"<text>"}"#
    static let stop = #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"Stop"}"#
    static let permissionPrompt = #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#

    /// `echo probe hello` under an ask rule: no suggestion, so the dialog is *1. Yes / 2. No*.
    static let bash = [
        prompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo probe hello","description":"Print probe hello"},"tool_use_id":"toolu_01SN"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo probe hello","description":"Print probe hello"}}"#,
        permissionPrompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo probe hello","description":"Print probe hello"},"tool_response":{"stdout":"probe hello","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_use_id":"toolu_01SN","duration_ms":31}"#,
        stop,
    ]

    /// Write of a new file: *1. Yes / 2. Yes, and switch to accept edits / 3. No*. Answered No (Esc): no hook follows
    /// the notification, only the transcript's `turn_duration`.
    static let write = [
        prompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/w/notes.txt","content":"hello\n"},"tool_use_id":"toolu_01NA"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"/w/notes.txt","content":"hello\n"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#,
        permissionPrompt,
    ]

    /// Edit of an existing file, every occurrence: *1. Yes / 2. Yes, and switch to accept edits / 3. No* under
    /// "Do you want to make this edit to existing.txt?".
    static let edit = [
        prompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/w/existing.txt","old_string":"<text>","new_string":"<text>","replace_all":true},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#,
        permissionPrompt,
    ]

    /// An MCP tool call: `mcp_server` on both hooks, a rule offered for the tool.
    static let mcp = [
        prompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"ToolSearch","tool_input":{"query":"select:mcp__probe__probe_echo","max_results":1},"tool_use_id":"toolu_01XN"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"ToolSearch","tool_input":{"query":"select:mcp__probe__probe_echo","max_results":1},"tool_response":{"matches":["mcp__probe__probe_echo"],"query":"select:mcp__probe__probe_echo","total_deferred_tools":230},"tool_use_id":"toolu_01XN","duration_ms":1}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"mcp__probe__probe_echo","tool_input":{"text":"hello probe"},"tool_use_id":"toolu_01G2","mcp_server":{"name":"probe","source":"dynamic"}}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"mcp__probe__probe_echo","tool_input":{"text":"hello probe"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"mcp__probe__probe_echo"}],"behavior":"allow","destination":"localSettings"}],"mcp_server":{"name":"probe","source":"dynamic"}}"#,
        permissionPrompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"mcp__probe__probe_echo","tool_input":{"text":"hello probe"},"tool_response":[{"type":"text","text":"hello probe"}],"tool_use_id":"toolu_01G2","duration_ms":92,"mcp_server":{"name":"probe","source":"dynamic"}}"#,
        stop,
    ]

    /// `AskUserQuestion`, one single-choice question: its own `PermissionRequest` and `permission_prompt` follow.
    static let question = [
        prompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color should the probe use?","header":"Color","options":[{"label":"Red","description":"Warm tone"},{"label":"Blue","description":"Cool tone"}],"multiSelect":false}]},"tool_use_id":"toolu_01XM"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color should the probe use?","header":"Color","options":[{"label":"Red","description":"Warm tone"},{"label":"Blue","description":"Cool tone"}],"multiSelect":false}]}}"#,
        permissionPrompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color should the probe use?","header":"Color","options":[{"label":"Red","description":"Warm tone"},{"label":"Blue","description":"Cool tone"}],"multiSelect":false}]},"tool_response":{"questions":[{"question":"Which color should the probe use?","header":"Color","options":[{"label":"Red","description":"Warm tone"},{"label":"Blue","description":"Cool tone"}],"multiSelect":false}],"answers":{"Which color should the probe use?":"Blue"},"annotations":{}},"tool_use_id":"toolu_01XM","duration_ms":4}"#,
        stop,
    ]

    /// `AskUserQuestion`, one multiple-choice question (`Lint, Build` chosen).
    static let multiSelect = #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which checks should run?","header":"Checks","options":[{"label":"Lint","description":"Style"},{"label":"Tests","description":"Unit tests"},{"label":"Build","description":"Compile"}],"multiSelect":true}]},"tool_use_id":"toolu_01MS"}"#

    /// `AskUserQuestion`, two single-choice questions.
    static let twoQuestions = #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}],"multiSelect":false},{"question":"Which size?","header":"Size","options":[{"label":"Small","description":"Tiny"},{"label":"Large","description":"Huge"}],"multiSelect":false}]},"tool_use_id":"toolu_01TQ"}"#

    /// `ExitPlanMode` in plan mode: the plan and the file it was written to.
    static let plan = [
        ###"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"plan","hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"## Plan\n\n- Create `hello.txt` in the project root (`/w`).\n- Put the single line `hi` in it.\n","planFilePath":"/home/.claude/plans/plan-add-a-file.md"},"tool_use_id":"toolu_01Qn"}"###,
        ###"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"plan","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"## Plan\n\n- Create `hello.txt` in the project root (`/w`).\n- Put the single line `hi` in it.\n","planFilePath":"/home/.claude/plans/plan-add-a-file.md"}}"###,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Notification","message":"Claude Code needs your approval for the plan","notification_type":"permission_prompt"}"#,
    ]

    /// An MCP tool that asks for a form once allowed: the permission, then `Elicitation`, its notification, the
    /// answer (Esc: `cancel`) and the tool's end.
    static let elicitation = [
        prompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"mcp__probe__probe_ask","tool_input":{},"tool_use_id":"toolu_01GL","mcp_server":{"name":"probe","source":"dynamic"}}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"mcp__probe__probe_ask","tool_input":{},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"mcp__probe__probe_ask"}],"behavior":"allow","destination":"localSettings"}],"mcp_server":{"name":"probe","source":"dynamic"}}"#,
        permissionPrompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Elicitation","mcp_server_name":"probe","message":"Pick a deployment tier","mode":"form","requested_schema":{"type":"object","properties":{"tier":{"type":"string","enum":["small","large"]}},"required":["tier"]}}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Notification","message":"Claude Code needs your input","notification_type":"elicitation_dialog"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"ElicitationResult","mcp_server_name":"probe","mode":"form","action":"cancel"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"Notification","message":"Elicitation response for server \"probe\": cancel","notification_type":"elicitation_response"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"mcp__probe__probe_ask","tool_input":{},"tool_response":[{"type":"text","text":"{\"action\": \"cancel\"}"}],"tool_use_id":"toolu_01GL","duration_ms":30056,"mcp_server":{"name":"probe","source":"dynamic"}}"#,
        stop,
    ]

    /// Two `Bash` calls in one message, both under the ask rule: both described at once, two notifications, the
    /// dialog asks `1 of 2` then `2 of 2`, and the first runs as soon as it is allowed.
    static let stacked = [
        prompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo probe alpha","description":"Print probe alpha"},"tool_use_id":"toolu_01DB"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo probe alpha","description":"Print probe alpha"}}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo probe beta","description":"Print probe beta"},"tool_use_id":"toolu_019a"}"#,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo probe beta","description":"Print probe beta"}}"#,
        permissionPrompt,
        permissionPrompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo probe alpha","description":"Print probe alpha"},"tool_response":{"stdout":"probe alpha","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_use_id":"toolu_01DB","duration_ms":25}"#,
        permissionPrompt,
        #"{"session_id":"s1","transcript_path":"/t.jsonl","cwd":"/w","permission_mode":"default","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo probe beta","description":"Print probe beta"},"tool_response":{"stdout":"probe beta","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"tool_use_id":"toolu_019a","duration_ms":28}"#,
        stop,
    ]
}
