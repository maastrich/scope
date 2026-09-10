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

    @Test func theInstructionsWarnAboutWhatOpeningAThreadCosts() {
        #expect(MCPBridge.instructions.contains("dry_run"))
        #expect(MCPBridge.instructions.lowercased().contains("depth"))
    }
}
