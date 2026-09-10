import Foundation
import MCP
import ScopeControl

// `scope mcp` — the same commands as the CLI, spoken as MCP on stdio.
//
// It holds no logic of its own: a tool call becomes a `ControlCall`, goes down the same socket, and the
// answer is rendered by the same code that prints for the terminal. Anything an agent can do here, the user
// can do from their shell, and the app decides in one place whether either is allowed.
//
// stdout belongs to the protocol: everything this file has to say goes to stderr.
enum ScopeMCP {
    static func run(options: ScopeCLI.Options) async throws {
        let client = ControlClient(
            socketPath: ControlEndpoint.resolve(socket: options.socket, home: options.home),
            client: "scope-mcp/\(scopeCLIVersion)"
        )
        let server = Server(
            name: MCPBridge.serverName,
            version: scopeCLIVersion,
            title: "Scope",
            instructions: MCPBridge.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPBridge.tools.map(tool))
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            await perform(parameters, with: client)
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// One tool call: arguments in, control call out, the app's answer back as text and structured content.
    private static func perform(_ parameters: CallTool.Parameters, with client: ControlClient) async -> CallTool.Result {
        let arguments: Data
        do {
            arguments = try JSONEncoder().encode(parameters.arguments ?? [:])
        } catch {
            return failure(.badRequest("unreadable arguments", detail: String(describing: error)))
        }
        switch MCPBridge.call(tool: parameters.name, arguments: arguments) {
        case .failure(let error):
            return failure(error)
        case .success(let call):
            do {
                let payload = try await client.call(call, onPending: { message in
                    FileHandle.standardError.write(Data("scope mcp: \(message)\n".utf8))
                })
                return CallTool.Result(
                    content: [.text(MCPBridge.text(for: payload))],
                    structuredContent: (try? MCPBridge.structured(for: payload)).flatMap {
                        try? JSONDecoder().decode(Value.self, from: $0)
                    }
                )
            } catch let error as ControlError {
                return failure(error)
            } catch {
                return failure(.failed(String(describing: error)))
            }
        }
    }

    /// A refusal an agent can act on: the message, and the detail that says what to do instead.
    private static func failure(_ error: ControlError) -> CallTool.Result {
        CallTool.Result(content: [.text(error.description)], isError: true)
    }

    private static func tool(_ tool: MCPTool) -> Tool {
        Tool(
            name: tool.name,
            description: tool.description,
            inputSchema: (try? JSONDecoder().decode(Value.self, from: Data(tool.schema.utf8))) ?? .object([:]),
            annotations: Tool.Annotations(title: tool.title, readOnlyHint: tool.readOnly,
                                          destructiveHint: tool.destructive, openWorldHint: false)
        )
    }
}
