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
    ///
    /// It is what the config stores, so it doubles as the editor's identity (`init(template:)`) and must not
    /// change: how the editor is actually driven lives in `arguments(for:)`.
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

    /// The order "Open in Editor" tries installed editors in when none was chosen (after the running ones).
    public static let detectionOrder: [KnownEditor] = [.zed, .cursor, .vscode, .sublime, .jetbrains, .nova]

    /// The known editor a stored template stands for; nil for a custom command.
    public init?(template: EditorTemplate) {
        guard let known = Self.allCases.first(where: { $0.template == template }) else { return nil }
        self = known
    }

    /// The command-line tool shipped inside the app bundle, relative to the bundle root. Preferred over the
    /// name on `PATH`: the shell command may never have been installed, and `code` on `PATH` is Cursor's shim
    /// on a machine where Cursor was installed last.
    public var bundledCLI: String {
        switch self {
        case .cursor: return "Contents/Resources/app/bin/cursor"
        case .vscode: return "Contents/Resources/app/bin/code"
        case .zed: return "Contents/MacOS/cli"
        case .sublime: return "Contents/SharedSupport/bin/subl"
        case .jetbrains: return "Contents/MacOS/idea"
        case .nova: return "Contents/SharedSupport/nova"
        }
    }

    /// The arguments (without the executable) that land `target` in a window of its own project, reusing the
    /// window when the project is already open.
    public func arguments(for target: EditorTarget) -> [String] {
        let position = target.file.map { file in target.line.map { "\(file):\($0)" } ?? file }
        switch self {
        case .cursor, .vscode:
            // A folder that is already open is focused, not duplicated. The folder goes with the file so the
            // file lands in its project's window instead of whichever window was used last.
            if let position { return [target.root, "-g", position] }
            if target.folders.count > 1, let workspace = target.workspace { return [workspace] }
            return target.folders
        case .zed:
            // `-e`: the window that already holds the folder, a new one otherwise. Without it Zed follows
            // `cli_default_open_behavior`, which is a new window per call for whoever chose "new_window".
            // Zed has no workspace file: a whole task is its sandboxes side by side.
            return ["-e"] + target.folders + (position.map { [$0] } ?? [])
        case .sublime:
            return position.map { [$0] } ?? target.folders
        case .jetbrains:
            guard let file = target.file else { return [target.root] }
            return [target.root] + (target.line.map { ["--line", String($0)] } ?? []) + [file]
        case .nova:
            guard let file = target.file else { return [target.root] }
            return (target.line.map { ["-l", String($0)] } ?? []) + [file]
        }
    }
}

/// What an "Open in Editor" gesture points at: one checkout, a file of it, or a whole task.
public struct EditorTarget: Sendable, Equatable {
    /// The one folder that stands for the target: the checkout, or the task root for a task of several.
    public var root: String
    /// The checkouts to show: `[root]` except for a whole task, which lists its sandboxes.
    public var folders: [String]
    /// A `.code-workspace` covering `folders`, for the editors that read one.
    public var workspace: String?
    /// Absolute path of the file to show, and its 1-based line.
    public var file: String?
    public var line: Int?

    /// A checkout, optionally on one of its files.
    public init(folder: String, file: String? = nil, line: Int? = nil) {
        self.root = folder
        self.folders = [folder]
        self.file = file.map { $0.hasPrefix("/") ? $0 : folder + "/" + $0 }
        self.line = line
    }

    /// A whole task. `root` is where its threads run (the sandbox itself for a one-repository task).
    public init(taskRoot root: String, sandboxes: [String], workspace: String?) {
        self.root = root
        self.folders = sandboxes.isEmpty ? [root] : sandboxes
        self.workspace = workspace
    }

    /// What ⌥-click copies.
    public var copiedPath: String { file ?? root }
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
    /// The full argv for `target`. A known editor is driven by `KnownEditor.arguments(for:)`; a custom command
    /// is expanded as written, on the target's root.
    func argv(for target: EditorTarget) -> [String] {
        if let known = KnownEditor(template: self), let name = argv.first {
            return [name] + known.arguments(for: target)
        }
        return expand(path: target.root, file: target.file, line: target.line)
    }

    /// Starts the editor on `target` without waiting for it (no pipes: an editor may never exit).
    ///
    /// A known editor runs the tool inside its app bundle when `locateApp` (bundle id → app URL) finds one;
    /// otherwise `argv[0]` is resolved against `searchPATH` (the login-shell PATH). `PATH` in the editor's
    /// environment is set to `searchPATH` so `code` / `cursor` shims find their app.
    func launch(_ target: EditorTarget, searchPATH: String, locateApp: (String) -> URL? = { _ in nil }) throws {
        let argv = argv(for: target)
        guard let first = argv.first, !first.isEmpty else { throw EditorLaunchError.emptyTemplate }
        let bundled = KnownEditor(template: self).flatMap { known in
            locateApp(known.bundleID).map { $0.appending(path: known.bundledCLI).path }
        }
        let executable: String
        if let bundled, ExecutableResolver.isExecutableFile(bundled) {
            executable = bundled
        } else if let resolved = ExecutableResolver.resolve(first, path: searchPATH, shell: ShellEnvironment.loginShell()) {
            executable = resolved
        } else {
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
