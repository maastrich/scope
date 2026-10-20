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
            client: "\(ControlClientName.mcp)/\(scopeCLIVersion)"
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
                var content: [Tool.Content] = [.text(text: MCPBridge.text(for: payload), annotations: nil, _meta: nil)]
                // A screenshot crosses the socket as a path (its cap is 1 MiB); the image is read here, on the agent's
                // side, and sent once — never again in `structuredContent`, which would double it.
                if case .browser(let result) = payload, let path = result.screenshot,
                   let data = FileManager.default.contents(atPath: path) {
                    content.append(.image(data: data.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil))
                }
                return CallTool.Result(
                    content: content,
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
        CallTool.Result(content: [.text(text: error.description, annotations: nil, _meta: nil)], isError: true)
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
