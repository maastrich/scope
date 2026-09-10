import Foundation

/// Where a scope's task sandboxes live (spec §3). `.insideScope` is a per-scope opt-in, unused in M0.
public enum SandboxLocation: String, Codable, Sendable, CaseIterable {
    /// `<SCOPE_HOME>/sandboxes/<scope-slug>/`
    case home
    /// `<scope>/.scope/sandboxes/`
    case insideScope
}

/// How the login-shell environment is probed before the first thread launch.
public enum ShellProbeMode: String, Codable, Sendable, CaseIterable {
    /// `<shell> -ilc` — sees rc files, closest to the user's own terminal.
    case interactiveLogin
    /// `<shell> -lc` — profile only.
    case login
    /// No probe; `path_helper` / the app's own environment is used.
    case none
}

/// Where the count of threads waiting for the user is shown, on top of the per-row marks that are always drawn
/// (a square state dot, a bar down the row and the word *needs you*).
///
/// The per-row marks only help for a row you can see; the counter is what catches a thread blocked further down a
/// long list or inside a collapsed task. Which of the two places suits a given screen is a matter of taste, hence
/// the preference.
public enum AttentionCounterPlacement: String, Codable, Sendable, CaseIterable {
    /// A banner under the scope switcher, only while something waits. Costs 24 pt of the list when shown.
    case sidebar
    /// A button in the window toolbar, always in the same place, counting every scope rather than the current one.
    case toolbar
    /// No counter: the row marks alone.
    case none

    /// What Settings shows.
    public var title: String {
        switch self {
        case .sidebar: "In the sidebar"
        case .toolbar: "In the toolbar"
        case .none: "Nowhere"
        }
    }
}

/// Whether the terminal follows the app appearance or stays dark.
public enum TerminalAppearanceMode: String, Codable, Sendable, CaseIterable {
    /// Light palette under the light appearance, dark palette under the dark one.
    case system
    /// The dark palette and ground in both appearances (UI direction A: agent TUIs assume a dark terminal).
    case alwaysDark
}

/// Shape of the terminal caret, and whether it blinks.
///
/// SwiftTerm's blink fades the whole caret layer in and out rather than switching it on and off, which reads
/// as a glow — hence a steady underline by default, and a preference for those who want the classic block.
/// A program may still ask for another shape at runtime (`DECSCUSR`); this is the shape a thread starts with
/// and the one every live terminal goes back to when the preference changes.
public enum TerminalCursorStyle: String, Codable, Sendable, CaseIterable {
    case steadyUnderline
    case blinkUnderline
    case steadyBar
    case blinkBar
    case steadyBlock
    case blinkBlock

    /// What Settings shows.
    public var title: String {
        switch self {
        case .steadyUnderline: "Underline"
        case .blinkUnderline: "Underline, blinking"
        case .steadyBar: "Bar"
        case .blinkBar: "Bar, blinking"
        case .steadyBlock: "Block"
        case .blinkBlock: "Block, blinking"
        }
    }

    /// `true` for the three blinking styles.
    public var blinks: Bool {
        switch self {
        case .blinkUnderline, .blinkBar, .blinkBlock: true
        case .steadyUnderline, .steadyBar, .steadyBlock: false
        }
    }
}

/// Command template used to open a folder or a file in the user's editor.
///
/// Placeholders: `{path}` (folder), `{file}` (absolute file path), `{line}` (1-based line).
/// Example: `["code", "-g", "{file}:{line}"]`.
public struct EditorTemplate: Codable, Sendable, Equatable {
    public var argv: [String]

    public init(argv: [String]) {
        self.argv = argv
    }

    /// Expands the template.
    ///
    /// - `{path}` is replaced by `path`.
    /// - When `file` is given, `{file}` is replaced by it (made absolute against `path` if relative)
    ///   and `{line}` by `line`; without a line, a `:{line}` suffix is dropped, and an argument that
    ///   is only `{line}` is dropped together with the option flag preceding it (`--line {line}`).
    /// - When `file` is `nil`, arguments mentioning `{file}` or `{line}` are dropped.
    /// - If the template never mentions the target (`{file}` with a file, `{path}` without), it is appended.
    public func expand(path: String, file: String? = nil, line: Int? = nil) -> [String] {
        let target: String? = file.map { $0.hasPrefix("/") ? $0 : path + "/" + $0 }
        var result: [String] = []
        var mentionedPath = false
        var mentionedFile = false

        for element in argv {
            var value = element
            if value.contains("{path}") {
                value = value.replacingOccurrences(of: "{path}", with: path)
                mentionedPath = true
            }
            if value.contains("{file}") || value.contains("{line}") {
                guard let target else { continue }
                value = value.replacingOccurrences(of: "{file}", with: target)
                if let line {
                    value = value.replacingOccurrences(of: "{line}", with: String(line))
                } else {
                    value = value.replacingOccurrences(of: ":{line}", with: "")
                    value = value.replacingOccurrences(of: "{line}", with: "")
                    if value.isEmpty {
                        // `--line {line}` without a line: drop the value and its flag.
                        if let last = result.last, last.hasPrefix("-") { result.removeLast() }
                        continue
                    }
                }
                mentionedFile = true
            }
            result.append(value)
        }

        if let target {
            if !mentionedFile { result.append(target) }
        } else if !mentionedPath {
            result.append(path)
        }
        return result
    }
}

/// A folder the user declared as a scope (spec §4.1).
public struct ScopeDeclaration: Codable, Sendable, Hashable, Identifiable {
    public var id: ScopeID
    /// Absolute, standardized (`URL.standardizedFileURL.path`): no tilde, no trailing slash, `/private` kept as given.
    public var path: String
    /// Display name; defaults to the last path component.
    public var name: String
    /// Unique across the config; names `graph/<slug>.json` and `sandboxes/<slug>/`.
    public var slug: String
    /// Repo discovery depth, clamped to `0...4`. A repo scope may use 0.
    public var discoveryDepth: Int
    public var sandboxes: SandboxLocation
    public var addedAt: Date

    /// Allowed discovery depths.
    public static let depthRange = 0...4

    public init(
        path: String,
        name: String? = nil,
        slug: String,
        discoveryDepth: Int = 1,
        sandboxes: SandboxLocation = .home,
        id: ScopeID = .generate(),
        addedAt: Date = .now
    ) {
        let normalized = ScopeDeclaration.normalizedPath(path)
        self.id = id
        self.path = normalized
        self.name = name ?? URL(fileURLWithPath: normalized).lastPathComponent
        self.slug = slug
        self.discoveryDepth = ScopeDeclaration.clampDepth(discoveryDepth)
        self.sandboxes = sandboxes
        self.addedAt = addedAt
    }

    /// `path` as a directory URL.
    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Expands `~`, standardizes and strips a trailing slash. Symlinks are kept (see `canonicalPath`).
    public static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    /// Symlink-resolved form used for comparisons only (`/private/tmp/x` and `/tmp/x` compare equal).
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: normalizedPath(path), isDirectory: true).resolvingSymlinksInPath().path
    }

    /// Clamps a depth to `depthRange`.
    public static func clampDepth(_ depth: Int) -> Int {
        min(max(depth, depthRange.lowerBound), depthRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, name, slug, discoveryDepth, sandboxes, addedAt
    }

    // Lenient decoding: hand-edited files may omit the optional fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = ScopeDeclaration.normalizedPath(try container.decode(String.self, forKey: .path))
        id = try container.decode(ScopeID.self, forKey: .id)
        self.path = path
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        slug = try container.decode(String.self, forKey: .slug)
        discoveryDepth = ScopeDeclaration.clampDepth(try container.decodeIfPresent(Int.self, forKey: .discoveryDepth) ?? 1)
        sandboxes = try container.decodeIfPresent(SandboxLocation.self, forKey: .sandboxes) ?? .home
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .now
    }
}

/// User preferences stored in `config.json`. Every field has a default so a partial document decodes.
public struct Preferences: Codable, Sendable, Equatable {
    /// Driver a scope starts on, before you open one in it. Empty — the default — means *automatic*: Scope
    /// takes the first agent profile it has, since running agents is what it is for; a shell is a choice.
    public var defaultDriverID: String
    /// Deprecated, unused since task branches are proposed by the driver (`TaskProposer`); kept so an
    /// older `config.json` still decodes. Empty by default.
    public var branchPrefix: String
    /// `nil` until detected or chosen in Settings.
    public var editor: EditorTemplate?
    public var shellProbe: ShellProbeMode
    public var confirmCloseRunningThread: Bool
    public var confirmQuitWithRunningThreads: Bool
    /// Menu bar item listing the threads waiting for the user (spec §7). On by default.
    public var showMenuBarExtra: Bool
    /// Terminal font size in points, clamped to `terminalFontSizeRange`; 13 by default.
    public var terminalFontSize: Int
    public var terminalAppearance: TerminalAppearanceMode
    /// Shape of the terminal caret; a steady underline by default.
    public var terminalCursorStyle: TerminalCursorStyle
    /// Exited threads close themselves (record deleted) when their 10 s exit toast goes. Off by default:
    /// the tab stays greyed until the user closes it.
    public var autoCloseExitedThreads: Bool
    /// Where the "N waiting for you" counter lives. In the sidebar by default.
    public var attentionCounter: AttentionCounterPlacement
    /// What agents may do through the control socket; `nil` means the defaults (see `AutomationSettings`).
    public var automation: AutomationSettings?

    /// Allowed terminal font sizes.
    public static let terminalFontSizeRange = 10...20

    /// Clamps a size to `terminalFontSizeRange`.
    public static func clampTerminalFontSize(_ size: Int) -> Int {
        min(max(size, terminalFontSizeRange.lowerBound), terminalFontSizeRange.upperBound)
    }

    public init(
        defaultDriverID: String = "",
        branchPrefix: String = "",
        editor: EditorTemplate? = nil,
        shellProbe: ShellProbeMode = .interactiveLogin,
        confirmCloseRunningThread: Bool = true,
        confirmQuitWithRunningThreads: Bool = true,
        showMenuBarExtra: Bool = true,
        terminalFontSize: Int = 13,
        terminalAppearance: TerminalAppearanceMode = .system,
        terminalCursorStyle: TerminalCursorStyle = .steadyUnderline,
        autoCloseExitedThreads: Bool = false,
        attentionCounter: AttentionCounterPlacement = .sidebar,
        automation: AutomationSettings? = nil
    ) {
        self.defaultDriverID = defaultDriverID
        self.branchPrefix = branchPrefix
        self.editor = editor
        self.shellProbe = shellProbe
        self.confirmCloseRunningThread = confirmCloseRunningThread
        self.confirmQuitWithRunningThreads = confirmQuitWithRunningThreads
        self.showMenuBarExtra = showMenuBarExtra
        self.terminalFontSize = Preferences.clampTerminalFontSize(terminalFontSize)
        self.terminalAppearance = terminalAppearance
        self.terminalCursorStyle = terminalCursorStyle
        self.autoCloseExitedThreads = autoCloseExitedThreads
        self.attentionCounter = attentionCounter
        self.automation = automation
    }

    public static let `default` = Preferences()

    private enum CodingKeys: String, CodingKey {
        case defaultDriverID, branchPrefix, editor, shellProbe, confirmCloseRunningThread, confirmQuitWithRunningThreads, showMenuBarExtra,
             terminalFontSize, terminalAppearance, terminalCursorStyle, autoCloseExitedThreads, attentionCounter,
             automation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences.default
        defaultDriverID = try container.decodeIfPresent(String.self, forKey: .defaultDriverID) ?? defaults.defaultDriverID
        branchPrefix = try container.decodeIfPresent(String.self, forKey: .branchPrefix) ?? defaults.branchPrefix
        editor = try container.decodeIfPresent(EditorTemplate.self, forKey: .editor)
        shellProbe = try container.decodeIfPresent(ShellProbeMode.self, forKey: .shellProbe) ?? defaults.shellProbe
        confirmCloseRunningThread = try container.decodeIfPresent(Bool.self, forKey: .confirmCloseRunningThread)
            ?? defaults.confirmCloseRunningThread
        confirmQuitWithRunningThreads = try container.decodeIfPresent(Bool.self, forKey: .confirmQuitWithRunningThreads)
            ?? defaults.confirmQuitWithRunningThreads
        showMenuBarExtra = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarExtra) ?? defaults.showMenuBarExtra
        terminalFontSize = Preferences.clampTerminalFontSize(
            try container.decodeIfPresent(Int.self, forKey: .terminalFontSize) ?? defaults.terminalFontSize)
        terminalAppearance = try container.decodeIfPresent(TerminalAppearanceMode.self, forKey: .terminalAppearance)
            ?? defaults.terminalAppearance
        terminalCursorStyle = try container.decodeIfPresent(TerminalCursorStyle.self, forKey: .terminalCursorStyle)
            ?? defaults.terminalCursorStyle
        autoCloseExitedThreads = try container.decodeIfPresent(Bool.self, forKey: .autoCloseExitedThreads)
            ?? defaults.autoCloseExitedThreads
        attentionCounter = try container.decodeIfPresent(AttentionCounterPlacement.self, forKey: .attentionCounter)
            ?? defaults.attentionCounter
        automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation)
    }

    /// The automation rules in force: what `config.json` says, or the defaults.
    public var automationSettings: AutomationSettings { automation ?? AutomationSettings() }
}

/// The whole `config.json` document.
public struct ScopeConfig: Codable, Sendable, Equatable {
    /// Schema version written by this build. Newer documents are refused, never overwritten.
    public static let currentVersion = 1

    public var version: Int
    /// Sidebar order.
    public var scopes: [ScopeDeclaration]
    public var preferences: Preferences

    public init(version: Int = ScopeConfig.currentVersion, scopes: [ScopeDeclaration] = [], preferences: Preferences = .default) {
        self.version = version
        self.scopes = scopes
        self.preferences = preferences
    }

    /// No scopes, default preferences.
    public static let empty = ScopeConfig()

    /// The declaration with `id`, if any.
    public func scope(id: ScopeID) -> ScopeDeclaration? {
        scopes.first { $0.id == id }
    }

    /// The declaration whose folder is `path`, comparing symlink-resolved paths on both sides.
    public func scope(path: String) -> ScopeDeclaration? {
        let wanted = ScopeDeclaration.canonicalPath(path)
        return scopes.first { ScopeDeclaration.canonicalPath($0.path) == wanted }
    }

    /// Slugs currently in use (for `SlugAllocator.unique`).
    public var takenSlugs: Set<String> {
        Set(scopes.map(\.slug))
    }

    private enum CodingKeys: String, CodingKey {
        case version, scopes, preferences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        scopes = try container.decodeIfPresent([ScopeDeclaration].self, forKey: .scopes) ?? []
        preferences = try container.decodeIfPresent(Preferences.self, forKey: .preferences) ?? .default
    }
}
