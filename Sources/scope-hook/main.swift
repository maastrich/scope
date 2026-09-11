import Foundation
import ScopeAdapters

// scope-hook — the one command every driver profile runs on an event.
//
//     scope-hook <event> [key=value ...] [--stdin]
//
// Reads SCOPE_THREAD and SCOPE_SOCK from the environment (injected by Scope into every thread), optionally
// embeds stdin (the driver's own hook JSON) as `raw`, and sends one HookEvent to the app's unix socket.
//
// With `--stdin` the driver's `session_id` (or Codex's `thread-id`) is lifted into `payload["session_id"]`
// so the app can resume the session later without parsing `raw`. The pseudo-event `notification` reads
// stdin and picks `permission.requested` or `input.requested` from Claude Code's `notification_type`
// (informational notifications send nothing).
//
// Exit codes: 64 for a usage error (unknown event, malformed argument); 0 in every other case, including
// "not running under Scope" and "socket unreachable", each with a one-line note on stderr. A driver hook
// must never be broken by Scope's absence.

/// The parsed command line.
struct HookCommand: Equatable {
    var event: HookCommandEvent
    var payload: [String: String]
    var readStdin: Bool

    enum ParseError: Error, Equatable {
        case missingEvent
        case unknownEvent(String)
        case malformedArgument(String)
        case help
    }

    static func parse(_ arguments: [String]) throws(ParseError) -> HookCommand {
        var event: HookCommandEvent?
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
                    guard let parsed = HookCommandEvent(word: argument) else { throw .unknownEvent(argument) }
                    event = parsed
                } else if let separator = argument.firstIndex(of: "="), separator != argument.startIndex {
                    let key = String(argument[..<separator])
                    payload[key] = String(argument[argument.index(after: separator)...])
                } else {
                    throw .malformedArgument(argument)
                }
            }
        }
        guard let event else { throw .missingEvent }
        return HookCommand(event: event, payload: payload, readStdin: readStdin || event.needsStdin)
    }
}

enum HookCLI {
    static let usageExit: Int32 = 64
    /// Raw stdin larger than this is truncated (the socket message stays far below the server's cap).
    static let maxRawBytes = 256 * 1024

    static var usage: String {
        let events = HookCommandEvent.allWords.joined(separator: " | ")
        return """
        usage: scope-hook <event> [key=value ...] [--stdin]
          event: \(events)
          --stdin  embed standard input (the driver's hook JSON) in the message and lift its session id
          notification  read stdin and derive permission.requested / input.requested from notification_type
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
        var parsedStdin = HookStdin()
        if command.readStdin {
            var data = stdin.readDataToEndOfFile()
            parsedStdin = HookStdin.parse(data)
            if data.count > maxRawBytes {
                data = data.prefix(maxRawBytes)
                note("stdin truncated to \(maxRawBytes) bytes")
            }
            raw = String(decoding: data, as: UTF8.self)
        }

        guard let event = Self.buildEvent(thread: thread, command: command, stdin: parsedStdin, raw: raw) else {
            note("notification '\(parsedStdin.notificationType ?? "?")' needs nobody; nothing sent")
            return 0
        }
        do {
            let payload = try event.encoded()
            try await UnixSocketClient.send(payload, to: socketPath, timeout: .seconds(2))
        } catch {
            note("could not deliver \(event.event.rawValue) to \(socketPath): \(error)")
            return 0
        }
        return 0
    }

    /// The wire event for a parsed command line and stdin; `nil` when there is nothing to send.
    /// An explicit `session_id=` (or `error=`) argument wins over the one lifted from stdin.
    static func buildEvent(thread: String, command: HookCommand, stdin: HookStdin, raw: String?) -> HookEvent? {
        guard let kind = command.event.resolve(stdin: stdin) else { return nil }
        var payload = command.payload
        if payload[HookEvent.sessionIDKey] == nil, let sessionID = stdin.sessionID {
            payload[HookEvent.sessionIDKey] = sessionID
        }
        if command.event == .notification {
            payload[HookEvent.viaKey] = HookEvent.viaNotification
        }
        if payload[HookEvent.errorKey] == nil, let error = stdin.error, !error.isEmpty {
            payload[HookEvent.errorKey] = error
        }
        return HookEvent(thread: thread, event: kind, payload: payload, sentAt: .now, raw: raw)
    }
}

let status = await HookCLI.run(arguments: Array(CommandLine.arguments.dropFirst()),
                               environment: ProcessInfo.processInfo.environment,
                               stdin: FileHandle.standardInput)
exit(status)
