import Foundation
import ScopeControl

// scope — the command line into a running Scope.
//
//     scope list
//     scope thread new --scope acme --prompt "look at the failing test"
//     scope task new "fix the flaky login test" --dry-run
//
// Everything it can do, `scope mcp` exposes to an agent; both are façades over the same `ControlCall`
// values, so neither can drift from the other. Exit codes: 64 for a usage error, 77 when Scope refused,
// 1 for anything else.

/// Version of the CLI, stamped by the build; `dev` in a plain `swift build`.
let scopeCLIVersion = ProcessInfo.processInfo.environment["SCOPE_CLI_VERSION"] ?? "dev"

enum ScopeCLIExit {
    static let usage: Int32 = 64
    static let denied: Int32 = 77
    static let failure: Int32 = 1
}

func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    handle.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
}

func run() async -> Int32 {
    let invocation: ScopeCLI.Invocation
    do {
        invocation = try ScopeCLI.parse(Array(CommandLine.arguments.dropFirst()))
    } catch let error as ScopeCLI.UsageError {
        write(error.description.trimmingCharacters(in: .whitespacesAndNewlines), to: .standardError)
        return ScopeCLIExit.usage
    } catch {
        write("scope: \(error)", to: .standardError)
        return ScopeCLIExit.usage
    }

    switch invocation {
    case .help(let text):
        write(text, to: .standardOutput)
        return 0
    case .version:
        write("scope \(scopeCLIVersion)", to: .standardOutput)
        return 0
    case .mcp(let options):
        do {
            try await ScopeMCP.run(options: options)
            return 0
        } catch {
            write("scope: the MCP server stopped: \(error)", to: .standardError)
            return ScopeCLIExit.failure
        }
    case .call(let call, let options):
        let client = ControlClient(
            socketPath: ControlEndpoint.resolve(socket: options.socket, home: options.home),
            client: "scope-cli/\(scopeCLIVersion)"
        )
        do {
            // Progress goes to stderr: `scope list --json | jq` stays clean.
            let payload = try await client.call(call, onPending: { message in
                write("scope: \(message)", to: .standardError)
            })
            write(options.json ? try CLIRenderer.json(payload) : CLIRenderer.text(payload), to: .standardOutput)
            return 0
        } catch let error as ControlError {
            write(CLIRenderer.text(error), to: .standardError)
            return error.code == .denied ? ScopeCLIExit.denied : ScopeCLIExit.failure
        } catch {
            write("scope: \(error)", to: .standardError)
            return ScopeCLIExit.failure
        }
    }
}

exit(await run())
