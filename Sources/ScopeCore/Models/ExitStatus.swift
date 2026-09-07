import Foundation

/// How a thread's process ended.
///
/// SwiftTerm 1.20.0 passes the raw `waitpid` status to `processTerminated(exitCode:)`, so every
/// exit goes through `decode(rawWaitStatus:)`: `exit 3` arrives as 768, `SIGTERM` as 15, an exec
/// failure as 32512 (`127 << 8`).
public struct ExitStatus: Codable, Sendable, Equatable {
    /// `WEXITSTATUS` when the process exited normally.
    public var code: Int32?
    /// `WTERMSIG` when the process was killed by a signal.
    public var signal: Int32?
    /// When the exit was observed.
    public var at: Date

    public init(code: Int32?, signal: Int32?, at: Date = .now) {
        self.code = code
        self.signal = signal
        self.at = at
    }

    /// Decodes a raw `waitpid` status. `nil` (SwiftTerm could not read the status) → unknown.
    public static func decode(rawWaitStatus: Int32?, at: Date = .now) -> ExitStatus {
        guard let status = rawWaitStatus else {
            return ExitStatus(code: nil, signal: nil, at: at)
        }
        let low = status & 0x7f
        if low == 0 {
            // WIFEXITED
            return ExitStatus(code: (status >> 8) & 0xff, signal: nil, at: at)
        }
        if low != 0x7f {
            // WIFSIGNALED (0x7f would be WIFSTOPPED, which never reaches us)
            return ExitStatus(code: nil, signal: low, at: at)
        }
        return ExitStatus(code: nil, signal: nil, at: at)
    }

    /// Exited normally with code 0.
    public var isClean: Bool { code == 0 }

    /// Exit 127: the shell or `execve` could not start the command.
    public var isExecFailure: Bool { code == 127 }

    /// `"exit 0"` · `"exit 1"` · `"killed by SIGHUP (1)"` · `"could not exec (127)"` · `"unknown"`.
    public var summary: String {
        if let code {
            return code == 127 ? "could not exec (127)" : "exit \(code)"
        }
        if let signal {
            return "killed by \(ExitStatus.signalName(signal)) (\(signal))"
        }
        return "unknown"
    }

    /// `"SIGHUP"` for 1, `"SIGTERM"` for 15, …; `"signal N"` for anything outside 1...31.
    public static func signalName(_ signal: Int32) -> String {
        let names = [
            "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "EMT", "FPE", "KILL", "BUS",
            "SEGV", "SYS", "PIPE", "ALRM", "TERM", "URG", "STOP", "TSTP", "CONT", "CHLD",
            "TTIN", "TTOU", "IO", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "INFO", "USR1", "USR2",
        ]
        let index = Int(signal) - 1
        guard index >= 0, index < names.count else { return "signal \(signal)" }
        return "SIG" + names[index]
    }
}
