import Foundation
import Testing
@testable import ScopeControl

/// The MCP façade: names, schemas, and the mapping onto the very same calls the CLI makes.
@Suite struct MCPBridgeTests {
    static func call(_ tool: String, _ json: String) -> Result<ControlCall, ControlError> {
        MCPBridge.call(tool: tool, arguments: Data(json.utf8))
    }

    @Test func everyToolHasAUsableSchema() throws {
        #expect(!MCPBridge.tools.isEmpty)
        for tool in MCPBridge.tools {
            #expect(tool.name.hasPrefix("scope_"))
            #expect(!tool.description.isEmpty)
            let schema = try JSONSerialization.jsonObject(with: Data(tool.schema.utf8)) as? [String: Any]
            #expect(schema?["type"] as? String == "object")
        }
    }

    /// Reading is marked read-only, and the one that writes to the user's repositories is marked destructive.
    @Test func theToolsSayWhatTheyDo() throws {
        let byName = Dictionary(uniqueKeysWithValues: MCPBridge.tools.map { ($0.name, $0) })
        #expect(byName["scope_list"]?.readOnly == true)
        #expect(byName["scope_ping"]?.readOnly == true)
        #expect(byName["scope_thread_new"]?.readOnly == false)
        #expect(byName["scope_task_new"]?.destructive == true)
    }

    /// Every tool maps onto a `ControlCall`; there is no second implementation to drift.
    @Test func everyToolMapsOntoACall() {
        #expect(Self.call("scope_ping", "{}") == .success(.ping))
        #expect(Self.call("scope_list", #"{"kind":"threads"}"#) == .success(.list(ListParams(kind: .threads))))
        #expect(Self.call("scope_thread_new", #"{"scope":"acme","prompt":"look at CI"}"#)
            == .success(.threadNew(ThreadNewParams(scope: "acme", prompt: "look at CI"))))
    }

    @Test func taskArgumentsAreSnakeCase() throws {
        let call = try Self.call("scope_task_new", #"{"prompt":"rework auth","dry_run":true,"open_thread":false,"repos":["api"]}"#).get()
        guard case .taskNew(let params) = call else {
            Issue.record("that is a task")
            return
        }
        #expect(params.dryRun)
        #expect(!params.openThread)
        #expect(params.repos == ["api"])
    }

    @Test func aTaskTakesAPullRequestToStartFrom() throws {
        let expected = ControlCall.taskNew(TaskNewParams(prompt: "review it", startPR: "#42"))
        #expect(try Self.call("scope_task_new", ##"{"prompt":"review it","start_pr":"#42"}"##).get() == expected)
        #expect(try Self.call("scope_task_new", ##"{"prompt":"review it","pr":"#42"}"##).get() == expected)
    }

    /// Changing the settings is the user's: it is no tool, so an agent is not even offered it.
    @Test func theSettingsAreNotATool() {
        #expect(!MCPBridge.tools.contains { $0.name.contains("config") })
    }

    @Test func aTaskWithoutAPromptIsRefused() {
        guard case .failure(let error) = Self.call("scope_task_new", #"{"repos":["api"]}"#) else {
            Issue.record("a task needs a prompt")
            return
        }
        #expect(error.code == .badRequest)
    }

    @Test func anUnknownKindFallsBackRatherThanFailing() throws {
        #expect(try Self.call("scope_list", #"{"kind":"submarines"}"#).get() == .list(ListParams()))
    }

    @Test func anUnknownToolIsUnsupported() {
        guard case .failure(let error) = Self.call("scope_teleport", "{}") else {
            Issue.record("there is no such tool")
            return
        }
        #expect(error.code == .unsupported)
    }

    /// The text an agent reads is the text the terminal prints: one renderer, two façades.
    @Test func theAnswerReadsTheSameOnBothSides() throws {
        let payload = ControlResultPayload.thread(ThreadNewResult(
            thread: "3f9a2c17be04", title: "acme", driver: "shell", scope: "Acme", scopeSlug: "acme",
            cwd: "/tmp/acme", task: nil, depth: 1))
        #expect(MCPBridge.text(for: payload) == CLIRenderer.text(payload))
        let structured = try JSONSerialization.jsonObject(with: try MCPBridge.structured(for: payload)) as? [String: Any]
        #expect(structured?["thread"] as? String == "3f9a2c17be04")
    }

    /// Agents are meant to act unattended: the instructions must not send them to dry-run and check first, but
    /// still say where Scope stops them.
    @Test func theInstructionsLetAgentsActAndNameTheLimits() {
        let text = MCPBridge.instructions.lowercased()
        #expect(!text.contains("dry_run"))
        #expect(text.contains("without asking"))
        #expect(text.contains("a task may create tasks"))
        #expect(text.contains("caps how many"))
        #expect(text.contains("a refusal is an answer"))
    }
}

/// The tools that act on existing threads and tasks.
@Suite struct MCPActionToolTests {
    static func call(_ tool: String, _ json: String) -> Result<ControlCall, ControlError> {
        MCPBridge.call(tool: tool, arguments: Data(json.utf8))
    }

    @Test func theActionToolsMapOntoTheirCalls() {
        #expect(Self.call("scope_thread_stop", #"{"thread":"3f9a2c17be04"}"#) == .success(.threadStop(ThreadTargetParams(thread: "3f9a2c17be04"))))
        #expect(Self.call("scope_thread_close", #"{"thread":"3f9a2c17be04"}"#) == .success(.threadClose(ThreadTargetParams(thread: "3f9a2c17be04"))))
        #expect(Self.call("scope_thread_send", #"{"thread":"3f9a2c17be04","text":"go"}"#)
            == .success(.threadSend(ThreadSendParams(thread: "3f9a2c17be04", text: "go", submit: true))))
        #expect(Self.call("scope_task_close", #"{"task":"t","delete_branch":true}"#)
            == .success(.taskClose(TaskCloseParams(task: "t", deleteBranch: true, force: false))))
        #expect(Self.call("scope_task_archive", #"{"task":"t"}"#) == .success(.taskArchive(TaskArchiveParams(task: "t"))))
        #expect(Self.call("scope_gc", "{}") == .success(.gc(GCParams())))
        #expect(Self.call("scope_gc", #"{"dry_run":true}"#) == .success(.gc(GCParams(dryRun: true))))
    }

    /// `dryRun` for `dry_run` once created the task it was meant to preview, because the decoder dropped it: an
    /// argument is now either understood as meant or refused before anything is decoded — never dropped.
    @Test func anUnknownArgumentIsRefusedNotDropped() throws {
        guard case .taskNew(let params) = try Self.call("scope_task_new", #"{"prompt":"x","dryRun":true}"#).get() else {
            Issue.record("that is a task"); return
        }
        #expect(params.dryRun, "another spelling of a declared name is that name")
        guard case .failure(let error) = Self.call("scope_task_close", #"{"task":"t","force":true}"#) else {
            Issue.record("force was accepted"); return
        }
        #expect(error.code == .badRequest && error.message.contains("force"))
        #expect(error.detail?.contains("It takes: delete_branch, task") == true)
        guard case .failure = Self.call("scope_list", #"{"kind":"threads","verbose":true}"#) else {
            Issue.record("verbose was accepted"); return
        }
    }

    /// The spellings agents guessed in real sessions, each of which used to cost a refused call.
    @Test func theCommandLineSpellingsAreUnderstood() throws {
        #expect(Self.call("scope_thread_send", #"{"thread":"3f9a2c17be04","message":"go"}"#)
            == .success(.threadSend(ThreadSendParams(thread: "3f9a2c17be04", text: "go"))))
        #expect(Self.call("scope_thread_send", #"{"thread_id":"3f9a2c17be04","text":"go","no_enter":true}"#)
            == .success(.threadSend(ThreadSendParams(thread: "3f9a2c17be04", text: "go", submit: false))))
        guard case .taskNew(let params) = try Self.call("scope_task_new",
            #"{"prompt":"x","noThread":true,"no-setup":true,"repo":"api"}"#).get() else {
            Issue.record("that is a task"); return
        }
        #expect(!params.openThread && !params.runSetup && params.repos == ["api"])
        #expect(Self.call("scope_task_archive", #"{"slug":"rate-limiting"}"#)
            == .success(.taskArchive(TaskArchiveParams(task: "rate-limiting"))))
        #expect(Self.call("scope_thread_read", #"{"id":"3f9a2c17be04","n":20}"#)
            == .success(.threadRead(ThreadReadParams(thread: "3f9a2c17be04", lines: 20))))
    }

    @Test func twoSpellingsOfOneArgumentAreRefused() {
        guard case .failure(let error) = Self.call("scope_thread_send", #"{"thread":"3f9a2c17be04","text":"a","message":"b"}"#) else {
            Issue.record("which text?"); return
        }
        #expect(error.code == .badRequest && error.message.contains("both set “text”"))
        guard case .failure = Self.call("scope_task_new", #"{"prompt":"x","open_thread":true,"no_thread":true}"#) else {
            Issue.record("open or not?"); return
        }
        guard case .failure = Self.call("scope_task_new", #"{"prompt":"x","no_thread":"yes"}"#) else {
            Issue.record("a negated flag takes a boolean"); return
        }
    }

    /// Every alias lands on an argument its tool declares: a typo in the table would turn a guess into a refusal.
    @Test func everyAliasNamesADeclaredArgument() throws {
        for (name, aliases) in MCPBridge.aliases {
            let tool = try #require(MCPBridge.tools.first { $0.name == name }, "\(name) is not a tool")
            let schema = try JSONSerialization.jsonObject(with: Data(tool.schema.utf8)) as? [String: Any]
            let declared = Set(((schema?["properties"] as? [String: Any]) ?? [:]).keys)
            for (alias, target) in aliases {
                let canonical: String = switch target {
                case .rename(let name), .negate(let name), .wrap(let name): name
                }
                #expect(declared.contains(canonical), "\(name): \(alias) → \(canonical)")
                #expect(!declared.contains(alias), "\(name): \(alias) is already declared")
            }
        }
    }

    @Test func closingIsMarkedDestructive() {
        let byName = Dictionary(uniqueKeysWithValues: MCPBridge.tools.map { ($0.name, $0) })
        #expect(byName["scope_thread_close"]?.destructive == true)
        #expect(byName["scope_task_close"]?.destructive == true)
        #expect(byName["scope_thread_send"]?.readOnly == false)
    }

    @Test func theUsageToolReadsAndMapsOntoTheSameCall() {
        #expect(MCPBridge.tools.first { $0.name == "scope_usage" }?.readOnly == true)
        #expect(Self.call("scope_usage", "{}") == .success(.usage(UsageParams())))
        #expect(Self.call("scope_usage", #"{"period":"yesterday","area":"command","limit":3}"#)
            == .success(.usage(UsageParams(period: "yesterday", area: "command", limit: 3))))
    }

    @Test func theSummaryToolReadsAndMapsOntoTheSameCall() {
        #expect(MCPBridge.tools.first { $0.name == "scope_summary" }?.readOnly == true)
        #expect(Self.call("scope_summary", "{}") == .success(.summary(SummaryParams())))
        #expect(Self.call("scope_summary", #"{"period":"last week","scope":"acme"}"#)
            == .success(.summary(SummaryParams(period: "last week", scope: "acme"))))
        #expect(Self.call("scope_summary", #"{"task":"auth-refresh"}"#) == .success(.summary(SummaryParams(task: "auth-refresh"))))
    }

    @Test func taskShowIsAReadAndTaskNewTakesADeliverable() throws {
        #expect(MCPBridge.tools.first { $0.name == "scope_task_show" }?.readOnly == true)
        #expect(Self.call("scope_task_show", #"{"task":"study"}"#) == .success(.taskShow(TaskShowParams(task: "study"))))
        guard case .taskNew(let params) = try Self.call("scope_task_new", #"{"prompt":"p","deliverable":"REPORT.md"}"#).get() else {
            Issue.record("not a task.new"); return
        }
        #expect(params.deliverable == "REPORT.md")
    }
}
