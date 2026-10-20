/// Records and hook payloads of real Claude Code sessions (2.1.299–2.1.304), anonymized like `ClaudeNativeFixtures`:
/// free text, paths and ids replaced by placeholders, server names by `server-*` (the plugin and claude.ai prefixes
/// kept, since they are what tells the source), then given the figures the tests need. Shapes, keys and enum values
/// are as Claude Code wrote them.
enum ClaudeSessionStateFixtures {
    // MARK: Transcript: successive `deferred_tools_delta` of one session

    /// At startup: every server still connecting. `needsAuthMcpServers` left out, as in most deltas.
    static let mcpAllPending = #"{"parentUuid":"<id>","isSidechain":false,"attachment":{"type":"deferred_tools_delta","addedNames":["<text>","<text>"],"addedLines":["<text>","<text>"],"removedNames":[],"wireHiddenNames":[],"readdedNames":[],"pendingMcpServers":["server-a","server-b","plugin:design:figma","claude.ai Linear"],"failedMcpServers":[]},"type":"attachment","uuid":"<id>","timestamp":"2026-10-20T09:00:01.000Z","userType":"external","entrypoint":"cli","cwd":"<path>","sessionId":"<id>","version":"2.1.304","gitBranch":"<branch>"}"#
    /// Moments later: the tools of the ones that came up, `authenticate` alone for the one that waits for a login, and
    /// one failure.
    static let mcpSettled = #"{"parentUuid":"<id>","isSidechain":false,"attachment":{"type":"deferred_tools_delta","addedNames":["mcp__server-a__search","mcp__server-a__fetch","mcp__claude_ai_Linear__list_issues","mcp__plugin_design_figma__authenticate","mcp__plugin_design_figma__complete_authentication"],"addedLines":["<text>"],"removedNames":[],"wireHiddenNames":[],"readdedNames":[],"pendingMcpServers":[],"failedMcpServers":[{"name":"server-b","error":"<text>","errorCode":"CONNECTION_CLOSED"}],"surfacedNames":["<text>"],"surfacedDefinitions":["<text>"]},"type":"attachment","uuid":"<id>","timestamp":"2026-10-20T09:00:09.000Z","userType":"external","entrypoint":"cli","cwd":"<path>","sessionId":"<id>","version":"2.1.304","gitBranch":"<branch>"}"#
    /// Later still: deferred tools only, no server list — says nothing about the servers.
    static let mcpToolsOnly = #"{"parentUuid":"<id>","isSidechain":false,"attachment":{"type":"deferred_tools_delta","addedNames":["<text>"],"addedLines":["<text>"],"removedNames":[],"wireHiddenNames":[],"readdedNames":[]},"type":"attachment","uuid":"<id>","timestamp":"2026-10-20T09:10:00.000Z","userType":"external","entrypoint":"cli","cwd":"<path>","sessionId":"<id>","version":"2.1.304","gitBranch":"<branch>"}"#
    /// A delta that does carry the authentication list.
    static let mcpNeedsAuth = #"{"parentUuid":"<id>","isSidechain":false,"attachment":{"type":"deferred_tools_delta","addedNames":[],"addedLines":[],"removedNames":[],"wireHiddenNames":[],"readdedNames":[],"pendingMcpServers":[],"failedMcpServers":[],"needsAuthMcpServers":["server-c"]},"type":"attachment","uuid":"<id>","timestamp":"2026-10-20T09:20:00.000Z","userType":"external","entrypoint":"cli","cwd":"<path>","sessionId":"<id>","version":"2.1.304","gitBranch":"<branch>"}"#

    // MARK: Transcript: compactions

    static let manualCompactBoundary = #"{"parentUuid":null,"logicalParentUuid":"<id>","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"<text>","isMeta":false,"timestamp":"2026-10-20T12:00:00.000Z","uuid":"<id>","level":"info","compactMetadata":{"trigger":"manual","preTokens":98000,"durationMs":35000,"preCompactDiscoveredTools":["<text>"],"postTokens":15000,"cumulativeDroppedTokens":0},"userType":"external","entrypoint":"cli","cwd":"<path>","sessionId":"<id>","version":"2.1.304","gitBranch":"<branch>","slug":"<slug>"}"#

    // MARK: Hooks (stdin as Claude Code sends it)

    static let sessionStart = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5-5"}"#
    static let modelSwitch = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"default","hook_event_name":"PostModelSwitch","from_model":"claude-opus-5-5","to_model":"claude-fable-5-1","source":"command","context_tokens":42000,"estimated_cache_write_usd":0.12}"#
    static let preCompactAuto = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"auto","hook_event_name":"PreCompact","trigger":"auto","custom_instructions":""}"#
    static let postCompactAuto = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"auto","hook_event_name":"PostCompact","trigger":"auto","compact_summary":"<text>"}"#
    static let enterPlanMode = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"plan","hook_event_name":"UserPromptSubmit","prompt":"<text>"}"#
    static let mcpToolCall = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"auto","hook_event_name":"PostToolUse","tool_name":"mcp__server-d__run_query","tool_input":{"query":"<text>"},"tool_response":[{"type":"text","text":"<text>"}],"tool_use_id":"toolu_mcp1","duration_ms":812}"#
    static let mcpToolFailure = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"auto","hook_event_name":"PostToolUseFailure","tool_name":"mcp__server-d__run_query","tool_input":{"query":"<text>"},"tool_use_id":"toolu_mcp2","error":"<text>"}"#
    static let prCreated = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"auto","effort":{"level":"high"},"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"<text>","description":"<text>"},"tool_response":{"stdout":"https://github.com/<owner>/<repo>/pull/57","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"gitOperation":{"push":{"branch":"<branch>"},"pr":{"number":57,"url":"https://github.com/<owner>/<repo>/pull/57","action":"created"}}},"tool_use_id":"toolu_pr1","duration_ms":3100}"#
    static let prMerged = #"{"session_id":"<id>","transcript_path":"<path>","cwd":"/work/api","permission_mode":"auto","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"<text>","description":"<text>"},"tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"gitOperation":{"pr":{"number":57,"url":"https://github.com/<owner>/<repo>/pull/57","action":"merged"}}},"tool_use_id":"toolu_pr2","duration_ms":2500}"#
    static let pushOnly = #"{"session_id":"<id>","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"<text>"},"tool_response":{"stdout":"","gitOperation":{"push":{"branch":"<branch>"}}},"tool_use_id":"toolu_push1"}"#
    static let prLink57 = #"{"type":"pr-link","sessionId":"<id>","prNumber":57,"prUrl":"https://github.com/<owner>/<repo>/pull/57","prRepository":"<owner>/<repo>","timestamp":"2026-10-20T13:00:05.000Z"}"#

    /// A `~/.claude.json` reduced to what `ClaudeMCPConfig` reads, with the secrets a real one holds beside it.
    static func claudeJSON(cwd: String) -> String {
        #"""
        {"numStartups":12,"oauthAccount":{"emailAddress":"<text>"},
         "mcpServers":{"server-a":{"type":"http","url":"https://example.invalid/mcp","headers":{"Authorization":"Bearer SECRET-TOKEN"}},
                       "server-b":{"command":"npx","args":["-y","<text>"],"env":{"API_KEY":"SECRET-KEY"}},
                       "shadowed":{"type":"stdio","command":"<text>"}},
         "projects":{"\#(cwd)":{"allowedTools":[],"mcpServers":{"server-local":{"type":"sse","url":"https://example.invalid/sse"},
                                                                "shadowed":{"type":"http","url":"https://example.invalid"}},
                                "disabledMcpServers":["server-b"],
                                "enabledMcpjsonServers":["server-project"],"disabledMcpjsonServers":["server-rejected"]},
                     "/elsewhere":{"mcpServers":{"server-other":{"type":"http","url":"https://example.invalid"}}}}}
        """#
    }

    static let mcpJSON = #"{"mcpServers":{"server-project":{"command":"<text>","args":[]},"server-rejected":{"type":"http","url":"https://example.invalid"},"server-unapproved":{"type":"http","url":"https://example.invalid"}}}"#
}
