import Foundation
import ScopeAdapters

// scope-hook — the one command every driver profile runs on an event.
//
//     scope-hook <event> [key=value ...] [--stdin]
//
// Reads SCOPE_THREAD and SCOPE_SOCK from the environment (injected by Scope into every thread), optionally
// embeds stdin (the driver's own hook JSON) as `raw`, and sends one HookEvent to the app's unix socket.
//
// Exit codes: 64 for a usage error (unknown event, malformed argument); 0 in every other case, including
// "not running under Scope" and "socket unreachable", each with a one-line note on stderr. A driver hook
// must never be broken by Scope's absence.

/// The parsed command line.
struct HookCommand: Equatable {
    var event: HookEvent.Kind
    var payload: [String: String]
    var readStdin: Bool

    enum ParseError: Error, Equatable {
        case missingEvent
        case unknownEvent(String)
        case malformedArgument(String)
        case help
    }

    static func parse(_ arguments: [String]) throws(ParseError) -> HookCommand {
        var event: HookEvent.Kind?
        var payload: [String: String] = [:]
        var readStdin = false
        for argument in arguments {
            switch argument {
            case "--stdin":
                readStdin = true
            case "--help", "-h":
                throw .help
            default:
                if event == nil {
                    guard let kind = HookEvent.Kind(rawValue: argument) else { throw .unknownEvent(argument) }
                    event = kind
                } else if let separator = argument.firstIndex(of: "="), separator != argument.startIndex {
                    let key = String(argument[..<separator])
                    payload[key] = String(argument[argument.index(after: separator)...])
                } else {
                    throw .malformedArgument(argument)
                }
            }
        }
        guard let event else { throw .missingEvent }
        return HookCommand(event: event, payload: payload, readStdin: readStdin)
    }
}

enum HookCLI {
    static let usageExit: Int32 = 64
    /// Raw stdin larger than this is truncated (the socket message stays far below the server's cap).
    static let maxRawBytes = 256 * 1024

    static var usage: String {
        let events = HookEvent.Kind.allCases.map(\.rawValue).joined(separator: " | ")
        return """
        usage: scope-hook <event> [key=value ...] [--stdin]
          event: \(events)
          --stdin  embed standard input (the driver's hook JSON) in the message
        """
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("scope-hook: \(message)\n".utf8))
    }

    static func run(arguments: [String], environment: [String: String], stdin: FileHandle) async -> Int32 {
        let command: HookCommand
        do {
            command = try HookCommand.parse(arguments)
        } catch {
            switch error {
            case .help:
                FileHandle.standardOutput.write(Data((usage + "\n").utf8))
                return 0
            case .missingEvent:
                note("missing event\n" + usage)
            case .unknownEvent(let name):
                note("unknown event '\(name)'\n" + usage)
            case .malformedArgument(let argument):
                note("expected key=value, got '\(argument)'\n" + usage)
            }
            return usageExit
        }

        guard let thread = environment["SCOPE_THREAD"], !thread.isEmpty else {
            note("not running under Scope (SCOPE_THREAD unset); nothing sent")
            return 0
        }
        guard let socketPath = environment["SCOPE_SOCK"], !socketPath.isEmpty else {
            note("SCOPE_SOCK unset; nothing sent")
            return 0
        }

        var raw: String?
        if command.readStdin {
            var data = stdin.readDataToEndOfFile()
            if data.count > maxRawBytes {
                data = data.prefix(maxRawBytes)
                note("stdin truncated to \(maxRawBytes) bytes")
            }
            raw = String(decoding: data, as: UTF8.self)
        }

        let event = HookEvent(thread: thread, event: command.event, payload: command.payload, sentAt: .now, raw: raw)
        do {
            let payload = try event.encoded()
            try await UnixSocketClient.send(payload, to: socketPath, timeout: .seconds(2))
        } catch {
            note("could not deliver \(command.event.rawValue) to \(socketPath): \(error)")
            return 0
        }
        return 0
    }
}

let status = await HookCLI.run(arguments: Array(CommandLine.arguments.dropFirst()),
                               environment: ProcessInfo.processInfo.environment,
                               stdin: FileHandle.standardInput)
exit(status)
