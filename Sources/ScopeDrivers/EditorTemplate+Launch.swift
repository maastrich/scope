import Foundation
import ScopeCore

/// Editors Scope knows how to detect (by bundle id) and how to launch (by CLI template). Spec §4.8.
public enum KnownEditor: String, CaseIterable, Sendable {
    case cursor, vscode, zed, sublime, jetbrains, nova

    /// Bundle id for `NSWorkspace.urlForApplication(withBundleIdentifier:)` (detection happens in the app target).
    public var bundleID: String {
        switch self {
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .vscode: return "com.microsoft.VSCode"
        case .zed: return "dev.zed.Zed"
        case .sublime: return "com.sublimetext.4"
        case .jetbrains: return "com.jetbrains.intellij"
        case .nova: return "com.panic.Nova"
        }
    }

    /// Name shown in Settings.
    public var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "Visual Studio Code"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .jetbrains: return "JetBrains IDE"
        case .nova: return "Nova"
        }
    }

    /// The CLI template; `{path}`, `{file}` and `{line}` are expanded by `EditorTemplate.expand`.
    public var template: EditorTemplate {
        switch self {
        case .cursor: return EditorTemplate(argv: ["cursor", "-g", "{file}:{line}"])
        case .vscode: return EditorTemplate(argv: ["code", "-g", "{file}:{line}"])
        case .zed: return EditorTemplate(argv: ["zed", "{file}:{line}"])
        case .sublime: return EditorTemplate(argv: ["subl", "{file}:{line}"])
        case .jetbrains: return EditorTemplate(argv: ["idea", "--line", "{line}", "{file}"])
        case .nova: return EditorTemplate(argv: ["nova", "-l", "{line}", "{file}"])
        }
    }
}

/// Why an editor could not be launched.
public enum EditorLaunchError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The template has no argv.
    case emptyTemplate
    /// `argv[0]` was not found on `searchedPATH`.
    case executableNotFound(String, searchedPATH: String)
    /// `Process.run()` failed.
    case launchFailed(String)

    public var description: String {
        switch self {
        case .emptyTemplate:
            return "The editor template is empty. Choose an editor in Settings."
        case .executableNotFound(let name, let path):
            return "\(name) not found in PATH (\(path.isEmpty ? "empty" : path)). Install the editor's command-line tool or edit the template in Settings."
        case .launchFailed(let message):
            return "The editor could not be started: \(message)"
        }
    }
}

public extension EditorTemplate {
    /// Expands the template and starts the editor without waiting for it (no pipes: an editor may never exit).
    /// `argv[0]` is resolved against `searchPATH` (the login-shell PATH), and `PATH` in the editor's environment
    /// is set to `searchPATH` so `code` / `cursor` shims find their app.
    func launch(path: String, file: String? = nil, line: Int? = nil, searchPATH: String) throws {
        let argv = expand(path: path, file: file, line: line)
        guard let first = argv.first, !first.isEmpty else { throw EditorLaunchError.emptyTemplate }
        guard let executable = ExecutableResolver.resolve(first, path: searchPATH, shell: ShellEnvironment.loginShell()) else {
            throw EditorLaunchError.executableNotFound(first, searchedPATH: searchPATH)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": searchPATH]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw EditorLaunchError.launchFailed(error.localizedDescription)
        }
    }
}
