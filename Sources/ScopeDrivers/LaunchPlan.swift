import Foundation

/// Everything `startProcess` needs, computed and checked before the fork so failures are readable.
public struct LaunchPlan: Sendable, Equatable {
    /// Absolute path of the executable.
    public var executable: String
    /// `argv[0]` override: `"-fish"` for login shells, nil to use `executable`.
    public var argv0: String?
    /// Arguments without `argv[0]`.
    public var arguments: [String]
    /// The complete child environment (see `TerminalEnvironment.build`).
    public var environment: [String: String]
    /// Working directory, verified to exist.
    public var cwd: String
    /// `"claude --resume 1b2c"` for the toolbar and logs.
    public var displayCommand: String

    public init(
        executable: String,
        argv0: String? = nil,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        displayCommand: String
    ) {
        self.executable = executable
        self.argv0 = argv0
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
        self.displayCommand = displayCommand
    }

    /// `environment` as the `"K=V"` array SwiftTerm takes.
    public var envp: [String] { TerminalEnvironment.envp(environment) }
}

/// Fresh launch (`command` + `args`) or resume (`resume` argv with the captured session id).
public enum LaunchMode: Sendable, Equatable {
    case launch
    case resume
}

/// Why a launch could not be planned or started.
public enum LaunchError: Error, Sendable, Equatable {
    /// `command` was not found: bare name absent from `searchedPATH`, or path not executable.
    case commandNotFound(command: String, searchedPATH: String, shell: String)
    /// The working directory does not exist (`chdir` failure would be silent in the child).
    case cwdMissing(String)
    /// A referenced placeholder has no value in this context.
    case placeholderUnavailable(DriverPlaceholder)
    /// The profile has no `resume` argv, or the thread has no `resumeID`.
    case resumeUnavailable
    /// `startProcess` left `process.running == false` (`forkpty` failed).
    case forkFailed
    /// The event adapter could not be prepared (e.g. the hooks settings file could not be written).
    case adapterSetupFailed(String)

    /// One line for a banner or a problem row.
    public var title: String {
        switch self {
        case .commandNotFound(let command, _, _):
            return "\(command) not found in PATH"
        case .cwdMissing:
            return "Working directory is missing"
        case .placeholderUnavailable(let placeholder):
            return "{\(placeholder.rawValue)} has no value"
        case .resumeUnavailable:
            return "This thread cannot be resumed"
        case .forkFailed:
            return "The process could not be started"
        case .adapterSetupFailed:
            return "The driver's event adapter could not be set up"
        }
    }

    /// Multi-line explanation with what to do next.
    public var detail: String {
        switch self {
        case .commandNotFound(let command, let searchedPATH, let shell):
            return """
            Searched the PATH resolved from \(shell):
            \(searchedPATH.isEmpty ? "(empty)" : searchedPATH)

            Install \(command), or edit the driver profile's "command" to an absolute path. \
            If the tool is on the PATH of your shell, re-probe the shell environment.
            """
        case .cwdMissing(let path):
            return "\(path) does not exist. Locate the folder or open a shell at the scope root instead."
        case .placeholderUnavailable(let placeholder):
            switch placeholder {
            case .resumeID:
                return "The driver profile references {resume_id} but no session id has been captured for this thread yet."
            case .task:
                return "The driver profile references {task} but this thread is not attached to a task."
            case .prompt:
                return "The driver profile references {prompt}, which is only available for headless runs and threads started with an initial prompt."
            case .scopeHook:
                return "The driver profile references {scope_hook} but the scope-hook binary was not found (neither embedded in the app nor on PATH)."
            default:
                return "The driver profile references {\(placeholder.rawValue)} but it has no value in this context."
            }
        case .resumeUnavailable:
            return "The driver profile has no \"resume\" command, or this thread has no session id to resume. Relaunch instead."
        case .forkFailed:
            return "forkpty failed. The system may be out of pseudo-terminals or processes; try closing other threads."
        case .adapterSetupFailed(let reason):
            return reason
        }
    }
}

/// Turns a profile + context into a `LaunchPlan`, or a readable `LaunchError`.
public enum LaunchPlanner {
    /// Steps: pick the argv for `mode`, expand placeholders, append `adapterArguments` (what the event
    /// adapter needs on the command line, e.g. `--settings <file>`; the same for a fresh launch and a
    /// resume), append the profile's `prompt` argv on a fresh launch with `values.prompt` set, resolve the
    /// executable against the login-shell PATH, verify `values.cwd` exists, build the child environment,
    /// set `argv0` for login shells.
    public static func plan(
        profile: DriverProfile,
        mode: LaunchMode,
        values: PlaceholderValues,
        shellEnvironment: ResolvedShellEnvironment,
        scopeVariables: TerminalEnvironment.ScopeVariables,
        appVersion: String,
        adapterArguments: [String] = [],
        helpers: String? = nil,
        fileExists: (String) -> Bool = { directoryExists($0) }
    ) throws(LaunchError) -> LaunchPlan {
        let rawArgv: [String]
        switch mode {
        case .launch:
            let promptArgv = values.prompt != nil ? (profile.prompt ?? []) : []
            rawArgv = [profile.command] + profile.args + promptArgv
        case .resume:
            guard let resume = profile.resume, !resume.isEmpty, values.resumeID != nil else {
                throw .resumeUnavailable
            }
            rawArgv = resume
        }

        let argv = try values.expand(rawArgv)
        guard let command = argv.first, !command.isEmpty else {
            throw .commandNotFound(command: profile.command, searchedPATH: shellEnvironment.path, shell: shellEnvironment.shell)
        }
        let arguments = Array(argv.dropFirst()) + adapterArguments

        guard let executable = ExecutableResolver.resolve(command, path: shellEnvironment.path, shell: shellEnvironment.shell) else {
            throw .commandNotFound(command: command, searchedPATH: shellEnvironment.path, shell: shellEnvironment.shell)
        }
        guard fileExists(values.cwd) else { throw .cwdMissing(values.cwd) }

        let driverEnv = try values.expand(profile.env)
        let environment = TerminalEnvironment.build(
            base: shellEnvironment.variables,
            shell: shellEnvironment.shell,
            cwd: values.cwd,
            scope: scopeVariables,
            driverEnv: driverEnv,
            appVersion: appVersion,
            helpers: helpers
        )

        let executableName = (executable as NSString).lastPathComponent
        let argv0 = profile.isLoginShell ? "-" + executableName : nil
        let displayName = command == "$SHELL" ? executableName : command
        let displayCommand = ([displayName] + arguments.map(quoteForDisplay)).joined(separator: " ")

        return LaunchPlan(
            executable: executable,
            argv0: argv0,
            arguments: arguments,
            environment: environment,
            cwd: values.cwd,
            displayCommand: displayCommand
        )
    }

    /// Default `fileExists`: an existing directory (a file is not a valid cwd).
    public static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func quoteForDisplay(_ argument: String) -> String {
        guard argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) else { return argument }
        return "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
