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
/// (a task's status glyph, a thread's square state dot).
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

/// The colours of the app's own chrome — grounds, hairlines, fills and text. The state colours are the same in both.
public enum ChromeTheme: String, Codable, Sendable, CaseIterable {
    /// The Mobsuccess 2026 charter, as written in its design system: an Ivory ground with pure-white cards and
    /// Ink text in light, Onyx with two raised navy surfaces and Ivory text in dark; borders and fills are the
    /// text colour at the charter's opacities.
    case brand
    /// Neutral greys: a white or near-black ground, grey chrome one step off it.
    case neutral

    public var title: String {
        switch self {
        case .brand: "Brand"
        case .neutral: "Neutral"
        }
    }
}

/// What Scope does when the default branch moves under an open task (spec §4.3, "a task follows main").
public enum FollowMainMode: String, Codable, Sendable, CaseIterable {
    /// The task's thread is told that main moved and asked to rebase — once per head of main — when the branch
    /// conflicts with it, or its pull request turned CONFLICTING. A clean lag is left to the agent.
    case askAgent
    /// Behind without conflicts and no thread at work: Scope rebases the sandbox itself and pushes with lease
    /// when the branch is published and its pull request open. A rebase that stops is aborted and the agent asked.
    case rebaseWhenClean
    /// Scope only measures and shows the lag.
    case never

    public var title: String {
        switch self {
        case .askAgent: "Ask the agent"
        case .rebaseWhenClean: "Rebase when clean"
        case .never: "Never"
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FollowMainMode(rawValue: raw) ?? .askAgent
    }
}

/// How much a sidebar row says.
public enum SidebarRows: String, Codable, Sendable, CaseIterable {
    /// Two lines: the name, then what the task or thread is doing, in words.
    case detailed
    /// One line: the name and the state mark.
    case compact

    public var title: String {
        switch self {
        case .detailed: "Detailed"
        case .compact: "Compact"
        }
    }
}

/// What a detailed row says of a thread whose turn is over.
public enum FinishedThreadLine: String, Codable, Sendable, CaseIterable {
    /// `Finished · 3m ago`; the reply's first line is in the row's help.
    case elapsed
    /// The first line of the agent's last reply.
    case reply

    public var title: String {
        switch self {
        case .elapsed: "When it finished"
        case .reply: "The first line of its reply"
        }
    }
}

/// How the sidebar orders the work of a scope.
public enum SidebarArrangement: String, Codable, Sendable, CaseIterable {
    /// Loose threads, then tasks, in a fixed order: a row never moves on its own.
    case tree
    /// What needs the user first, then what is working, finished, quiet: rows move as their state changes.
    case byState

    public var title: String {
        switch self {
        case .tree: "As a tree"
        case .byState: "By state"
        }
    }
}

/// Whether a thread or task an agent opened (`scope thread new`, `scope task new`, the MCP tools) comes to the
/// front. What the user opens always does.
///
/// Showing it replaces the terminal being read and moves the inspector with it, which is wrong while reading and
/// right when watching agents hand work to each other — hence the preference.
public enum AgentOpenedFocus: String, Codable, Sendable, CaseIterable {
    /// Only when its scope is on screen with no thread shown: nothing is being read.
    case whenIdle
    /// Never: the row and its state mark say it is there.
    case never
    /// Always, as the app did before the preference existed.
    case always

    /// What Settings shows.
    public var title: String {
        switch self {
        case .whenIdle: "Only when no thread is on screen"
        case .never: "Never"
        case .always: "Always"
        }
    }

    /// `threadShown`: a thread is on screen. `sameScope`: what opened belongs to the scope the sidebar shows.
    public func takesSelection(threadShown: Bool, sameScope: Bool) -> Bool {
        switch self {
        case .whenIdle: !threadShown && sameScope
        case .never: false
        case .always: true
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
                guard let target else {
                    // `--line {line}` on a folder: the flag goes with its value, or it would swallow the path.
                    if element == "{line}", let last = result.last, last.hasPrefix("-") { result.removeLast() }
                    continue
                }
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

/// What the scope's config says about one repository's sandboxes, over what its graph card says. Every field is
/// optional: an absent one leaves the card's value, an empty command turns the card's off.
public struct RepoCommandOverride: Codable, Sendable, Hashable {
    /// Runs in each new sandbox, after the files are copied and before the first thread starts.
    public var setup: String?
    /// Runs before a sandbox is removed (archive, close).
    public var teardown: String?
    /// Globs of the base checkout copied into each new sandbox; `[".env*"]` when absent.
    public var copyFiles: [String]?

    public init(setup: String? = nil, teardown: String? = nil, copyFiles: [String]? = nil) {
        self.setup = setup
        self.teardown = teardown
        self.copyFiles = copyFiles
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
    /// Per-repository overrides of the setup / teardown commands and the copied files, keyed by the repository's
    /// path relative to the scope root (`"."` for a repo scope). Edited by hand in `config.json`.
    public var repoCommands: [String: RepoCommandOverride]
    /// What the scope's tile shows in place of the first letter of its name: an emoji or a letter or two.
    public var icon: String?
    /// The tile's colour; `nil` derives one from the slug (`resolvedTint`).
    public var tint: ScopeTint?
    /// File name of the scope's image under `ScopeHome.scopeLogosURL`: a normalised copy (`ScopeLogo`), so the
    /// app neither writes in the scope's folder nor depends on a path the user may move. Shown in place of the
    /// letter.
    public var logo: String?
    /// The image shown in the dark appearance instead of `logo`; `nil` shows `logo` in both.
    public var logoDark: String?
    /// What every agent working in this scope should know, in the owner's words: added to the context file of
    /// each task.
    public var context: String?
    /// The model threads of this scope open on when nothing names one, ahead of the driver's default in Settings
    /// (`ModelChoice`); `nil` defers to that.
    public var model: String?
    /// What happens to this scope's tasks when their default branch moves, when it differs from the preference
    /// (`Preferences.followMain`). Edited by hand in `config.json`; `nil` follows the preference.
    public var followMain: FollowMainMode?
    /// Whether a task of this scope may be tried in the user's own checkout, when it differs from the preference
    /// (`Preferences.allowTryInCheckout`). Edited by hand in `config.json`; `nil` follows the preference.
    public var allowTryInCheckout: Bool?

    /// Allowed discovery depths.
    public static let depthRange = 0...4

    public init(
        path: String,
        name: String? = nil,
        slug: String,
        discoveryDepth: Int = 1,
        sandboxes: SandboxLocation = .home,
        id: ScopeID = .generate(),
        addedAt: Date = .now,
        repoCommands: [String: RepoCommandOverride] = [:],
        icon: String? = nil,
        tint: ScopeTint? = nil,
        logo: String? = nil,
        logoDark: String? = nil,
        context: String? = nil,
        model: String? = nil,
        followMain: FollowMainMode? = nil,
        allowTryInCheckout: Bool? = nil
    ) {
        self.followMain = followMain
        self.allowTryInCheckout = allowTryInCheckout
        self.repoCommands = repoCommands
        self.icon = icon
        self.tint = tint
        self.logo = logo
        self.logoDark = logoDark
        self.context = context
        self.model = model
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
        case id, path, name, slug, discoveryDepth, sandboxes, addedAt, repoCommands, icon, tint, logo, logoDark, context, model,
             followMain, allowTryInCheckout
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
        repoCommands = try container.decodeIfPresent([String: RepoCommandOverride].self, forKey: .repoCommands) ?? [:]
        icon = try? container.decodeIfPresent(String.self, forKey: .icon)
        tint = try? container.decodeIfPresent(ScopeTint.self, forKey: .tint)
        logo = try? container.decodeIfPresent(String.self, forKey: .logo)
        logoDark = try? container.decodeIfPresent(String.self, forKey: .logoDark)
        context = try? container.decodeIfPresent(String.self, forKey: .context)
        model = ((try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        followMain = try? container.decodeIfPresent(FollowMainMode.self, forKey: .followMain)
        allowTryInCheckout = try? container.decodeIfPresent(Bool.self, forKey: .allowTryInCheckout)
    }

    /// The override for a repository, looked up whatever spelling the config used for its path.
    public func commandOverride(for repoRelativePath: String) -> RepoCommandOverride? {
        func key(_ path: String) -> String {
            var p = path.trimmingCharacters(in: .whitespaces)
            while p.hasPrefix("./") { p.removeFirst(2) }
            while p.hasSuffix("/") { p.removeLast() }
            return p.isEmpty ? "." : p
        }
        let wanted = key(repoRelativePath)
        return repoCommands.first { key($0.key) == wanted }?.value
    }
}

/// Which models the assistant may use (spec §4.10).
public enum AssistMode: String, Codable, Sendable, CaseIterable {
    /// Nothing is read, nothing is classified.
    case off
    /// Apple's on-device model only: free, local, and silent when the machine has none.
    case onDevice
    /// The on-device model first; the driver's light model (Haiku, no tools) as a second opinion on a stuck verdict and
    /// as the fallback when the on-device model is unavailable, under `assistDailyCap`.
    case onDeviceAndHaiku

    public var allowsSecondTier: Bool { self == .onDeviceAndHaiku }
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
    /// `true` makes ⌥ send `ESC` before the key (the Meta of old terminals). Off by default, as in Terminal
    /// and iTerm: with it on, a layout that types braces with ⌥ cannot type them at all. `⌥←`, `⌥→`, `⌥⌫`
    /// and `⌥⌦` keep working either way (see `TerminalOptionKey`).
    public var terminalOptionAsMeta: Bool
    /// Claude Code draws with the terminal's 16 ANSI colours (its `dark-ansi` / `light-ansi` theme, picked to
    /// match the palette at launch) instead of its own true-colour theme, so its output follows the app's
    /// appearance. On by default. Off leaves Claude Code's own theme setting alone.
    public var claudeUsesTerminalPalette: Bool
    /// Exited threads close themselves (record deleted) when their 10 s exit toast goes. Off by default:
    /// the tab stays greyed until the user closes it.
    public var autoCloseExitedThreads: Bool
    /// Threads whose process was running when the app went down (quit, update, crash) start again when it opens,
    /// resuming the driver session when they can. On by default; holding ⇧ while the app opens skips it once.
    public var autoRelaunchThreads: Bool
    /// A relaunched thread whose turn the restart cut short is asked to go on from where its worktree stands
    /// (`InterruptedTurn`), once its driver is back at its prompt. On by default; ⇧ at launch skips it with the
    /// relaunch.
    public var resumeInterruptedTurns: Bool
    /// Driver of the orchestrator every scope keeps at its root (`ResidentRole.orchestrator`). Empty — the default —
    /// means *automatic*: `defaultDriverID` unless that is the shell, else the first agent profile installed. A running
    /// orchestrator keeps its driver until it next starts.
    public var orchestratorDriverID: String
    /// The model each driver opens on when neither the request nor the scope names one, by profile id
    /// (Settings ▸ Drivers ▸ Default model). Empty — the default — leaves the driver to its own.
    public var driverModels: [String: String]
    /// Where the "N waiting for you" counter lives. In the sidebar by default.
    public var attentionCounter: AttentionCounterPlacement
    /// Whether what an agent opens comes to the front. Only when nothing is being read, by default.
    public var agentOpenedFocus: AgentOpenedFocus
    /// Detailed by default.
    public var sidebarRows: SidebarRows
    /// As a tree by default.
    public var sidebarArrangement: SidebarArrangement
    /// When it finished, by default.
    public var finishedThreadLine: FinishedThreadLine
    /// By importance by default.
    public var scopeTileOrder: ScopeTileOrder
    /// A two-finger horizontal swipe over the sidebar switches scope. On by default.
    public var swipeBetweenScopes: Bool
    /// The New Thread / New Task buttons under the sidebar. Off by default: ⌘T, ⇧⌘T, the palette, the CLI and the
    /// orchestrator open threads and tasks, and the list takes the height the footer gave up.
    public var showSidebarFooter: Bool
    /// The brand's by default.
    public var chromeTheme: ChromeTheme
    /// Commit…, Push, Create PR and Merge under the Delta panel. Off by default: committing and shipping is the
    /// agent's work in its thread, and the panel is for reading what it did. Pulling a base checkout, opening a
    /// pull request and asking a thread to fix conflicts are not part of this and stay.
    public var showGitActions: Bool
    /// What agents may do through the control socket; `nil` means the defaults (see `AutomationSettings`).
    public var automation: AutomationSettings?
    /// Scope tidies up after tasks on its own — at launch, every 30 minutes and after each archive: leftover
    /// sandbox folders, stale git worktrees, processes of tasks that are gone, salvage refs past their 30 days.
    /// On by default.
    public var cleanUpAutomatically: Bool
    /// A notification quotes the agent — its question, the opening of its answer — rather than only saying what
    /// happened. On by default; off keeps the words off screen while sharing it.
    public var notificationsQuoteAgent: Bool
    /// Keep a log of which controls, commands and panels are used, under `SCOPE_HOME/usage` and nowhere else (`scope
    /// usage` reads it). On by default.
    public var recordUsage: Bool
    /// A task is archived once a background refresh sees its pull request merged and none of its threads is at
    /// work. On by default.
    public var archiveMergedTasks: Bool
    /// Days without thread activity after which an open task is called idle (`TaskDormancy`); 0 never. 3 by default.
    public var dormantAfterDays: Int
    /// What happens to an open task when the default branch moves under it (`FollowMainMode`). A scope's
    /// declaration may override it (`ScopeDeclaration.followMain`). Ask the agent, by default.
    public var followMain: FollowMainMode
    /// "Try in my checkout" is offered on tasks: the user's own base checkout can be detached onto a task's branch
    /// and put back (spec §4.5, the one exception to the untouchable base). Off by default; a scope's declaration
    /// may override it (`ScopeDeclaration.allowTryInCheckout`).
    public var allowTryInCheckout: Bool

    /// The token meter in the toolbar: what Claude Code threads consumed over five hours and seven days. On by default.
    public var showTokenMeter: Bool
    /// Tokens the user expects to spend per five hours; above 0 the meter becomes a gauge against it. Scope cannot know
    /// a plan's real limit, so it is the user's own figure. 0 by default: consumption only.
    public var tokenBudgetPer5h: Int
    /// The meter's breakdown adds what the tokens would have cost on the API. Off by default: a subscription is not
    /// billed per token.
    public var showAPICost: Bool
    /// Coming back to a scope shows what moved since it was last looked at — turns finished, questions, pull
    /// requests merged, checks failing — in a strip at the top of the sidebar. On by default.
    public var showReturnDigest: Bool
    /// How long the app must have been in the background for coming back to it to count as a return. 20 by default.
    public var returnDigestAwayMinutes: Int
    /// The system-wide chord that opens the quick panel (spec §7); `nil` registers none. ⌥Space by default.
    public var quickPanelHotkey: KeyChord?
    /// The system-wide chord that brings the main window up or hides the app; `nil` registers none. ⌥⇧Space by default.
    public var toggleWindowHotkey: KeyChord?
    /// Which tab the quick panel opens on. Inbox while a thread waits, Ask otherwise, by default.
    public var quickPanelLanding: QuickPanel.Landing

    /// The assistant that reads threads on events (spec §4.10): off, the on-device model only, or that model with the
    /// driver's light model as a capped second opinion. On-device only by default.
    public var assist: AssistMode
    /// Most calls the second tier may make per day. 40 by default.
    public var assistDailyCap: Int
    /// A finished turn the assistant reads as informational posts no notification. On by default.
    public var assistQuietsInformational: Bool
    /// A task created without a topic is filed under one of the scope's topics when the assistant can tell. On by default.
    public var assistPicksTopic: Bool
    /// A task whose last reply reads as final shows "Looks finished — archive?" in its band. On by default.
    public var assistSuggestsArchive: Bool

    /// Allowed values of `assistDailyCap`.
    public static let assistDailyCapRange = 1...500

    /// Allowed values of `returnDigestAwayMinutes`.
    public static let returnDigestAwayRange = 1...240

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
        terminalOptionAsMeta: Bool = false,
        claudeUsesTerminalPalette: Bool = true,
        autoCloseExitedThreads: Bool = false,
        autoRelaunchThreads: Bool = true,
        resumeInterruptedTurns: Bool = true,
        orchestratorDriverID: String = "",
        driverModels: [String: String] = [:],
        attentionCounter: AttentionCounterPlacement = .sidebar,
        agentOpenedFocus: AgentOpenedFocus = .whenIdle,
        sidebarRows: SidebarRows = .detailed,
        sidebarArrangement: SidebarArrangement = .tree,
        finishedThreadLine: FinishedThreadLine = .elapsed,
        scopeTileOrder: ScopeTileOrder = .byImportance,
        swipeBetweenScopes: Bool = true,
        showSidebarFooter: Bool = false,
        chromeTheme: ChromeTheme = .brand,
        showGitActions: Bool = false,
        automation: AutomationSettings? = nil,
        cleanUpAutomatically: Bool = true,
        notificationsQuoteAgent: Bool = true,
        recordUsage: Bool = true,
        archiveMergedTasks: Bool = true,
        dormantAfterDays: Int = 3,
        followMain: FollowMainMode = .askAgent,
        allowTryInCheckout: Bool = false,
        showTokenMeter: Bool = true,
        tokenBudgetPer5h: Int = 0,
        showAPICost: Bool = false,
        showReturnDigest: Bool = true,
        returnDigestAwayMinutes: Int = 20,
        assist: AssistMode = .onDevice,
        assistDailyCap: Int = 40,
        assistQuietsInformational: Bool = true,
        assistPicksTopic: Bool = true,
        assistSuggestsArchive: Bool = true,
        quickPanelHotkey: KeyChord? = .optionSpace,
        toggleWindowHotkey: KeyChord? = .optionShiftSpace,
        quickPanelLanding: QuickPanel.Landing = .inboxWhenWaiting
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
        self.terminalOptionAsMeta = terminalOptionAsMeta
        self.claudeUsesTerminalPalette = claudeUsesTerminalPalette
        self.autoCloseExitedThreads = autoCloseExitedThreads
        self.autoRelaunchThreads = autoRelaunchThreads
        self.resumeInterruptedTurns = resumeInterruptedTurns
        self.orchestratorDriverID = orchestratorDriverID
        self.driverModels = driverModels
        self.attentionCounter = attentionCounter
        self.agentOpenedFocus = agentOpenedFocus
        self.sidebarRows = sidebarRows
        self.sidebarArrangement = sidebarArrangement
        self.finishedThreadLine = finishedThreadLine
        self.scopeTileOrder = scopeTileOrder
        self.swipeBetweenScopes = swipeBetweenScopes
        self.showSidebarFooter = showSidebarFooter
        self.chromeTheme = chromeTheme
        self.showGitActions = showGitActions
        self.automation = automation
        self.cleanUpAutomatically = cleanUpAutomatically
        self.notificationsQuoteAgent = notificationsQuoteAgent
        self.recordUsage = recordUsage
        self.archiveMergedTasks = archiveMergedTasks
        self.dormantAfterDays = max(0, dormantAfterDays)
        self.followMain = followMain
        self.allowTryInCheckout = allowTryInCheckout
        self.showTokenMeter = showTokenMeter
        self.tokenBudgetPer5h = max(0, tokenBudgetPer5h)
        self.showAPICost = showAPICost
        self.showReturnDigest = showReturnDigest
        self.returnDigestAwayMinutes = min(max(returnDigestAwayMinutes, Self.returnDigestAwayRange.lowerBound),
                                           Self.returnDigestAwayRange.upperBound)
        self.assist = assist
        self.assistDailyCap = min(max(assistDailyCap, Self.assistDailyCapRange.lowerBound), Self.assistDailyCapRange.upperBound)
        self.assistQuietsInformational = assistQuietsInformational
        self.assistPicksTopic = assistPicksTopic
        self.assistSuggestsArchive = assistSuggestsArchive
        self.quickPanelHotkey = quickPanelHotkey
        self.toggleWindowHotkey = toggleWindowHotkey
        self.quickPanelLanding = quickPanelLanding
    }

    public static let `default` = Preferences()

    private enum CodingKeys: String, CodingKey {
        case defaultDriverID, branchPrefix, editor, shellProbe, confirmCloseRunningThread, confirmQuitWithRunningThreads, showMenuBarExtra,
             terminalFontSize, terminalAppearance, terminalCursorStyle, terminalOptionAsMeta, claudeUsesTerminalPalette, autoCloseExitedThreads,
             attentionCounter, agentOpenedFocus, sidebarRows, sidebarArrangement, finishedThreadLine, scopeTileOrder, swipeBetweenScopes, showSidebarFooter, chromeTheme, showGitActions,
             automation, autoRelaunchThreads, resumeInterruptedTurns, cleanUpAutomatically, orchestratorDriverID, driverModels, notificationsQuoteAgent, recordUsage, archiveMergedTasks, dormantAfterDays,
             followMain, allowTryInCheckout, showTokenMeter, tokenBudgetPer5h, showAPICost, showReturnDigest, returnDigestAwayMinutes,
             assist, assistDailyCap, assistQuietsInformational, assistPicksTopic, assistSuggestsArchive,
             quickPanelHotkey, toggleWindowHotkey, quickPanelLanding
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
        terminalOptionAsMeta = try container.decodeIfPresent(Bool.self, forKey: .terminalOptionAsMeta)
            ?? defaults.terminalOptionAsMeta
        claudeUsesTerminalPalette = try container.decodeIfPresent(Bool.self, forKey: .claudeUsesTerminalPalette)
            ?? defaults.claudeUsesTerminalPalette
        autoCloseExitedThreads = try container.decodeIfPresent(Bool.self, forKey: .autoCloseExitedThreads)
            ?? defaults.autoCloseExitedThreads
        autoRelaunchThreads = try container.decodeIfPresent(Bool.self, forKey: .autoRelaunchThreads)
            ?? defaults.autoRelaunchThreads
        resumeInterruptedTurns = try container.decodeIfPresent(Bool.self, forKey: .resumeInterruptedTurns)
            ?? defaults.resumeInterruptedTurns
        orchestratorDriverID = (try? container.decodeIfPresent(String.self, forKey: .orchestratorDriverID))
            ?? defaults.orchestratorDriverID
        driverModels = ((try? container.decodeIfPresent([String: String].self, forKey: .driverModels)) ?? nil) ?? defaults.driverModels
        attentionCounter = try container.decodeIfPresent(AttentionCounterPlacement.self, forKey: .attentionCounter)
            ?? defaults.attentionCounter
        agentOpenedFocus = (try? container.decodeIfPresent(AgentOpenedFocus.self, forKey: .agentOpenedFocus))
            ?? defaults.agentOpenedFocus
        sidebarRows = (try? container.decodeIfPresent(SidebarRows.self, forKey: .sidebarRows)) ?? defaults.sidebarRows
        sidebarArrangement = (try? container.decodeIfPresent(SidebarArrangement.self, forKey: .sidebarArrangement))
            ?? defaults.sidebarArrangement
        finishedThreadLine = (try? container.decodeIfPresent(FinishedThreadLine.self, forKey: .finishedThreadLine))
            ?? defaults.finishedThreadLine
        scopeTileOrder = (try? container.decodeIfPresent(ScopeTileOrder.self, forKey: .scopeTileOrder)) ?? defaults.scopeTileOrder
        swipeBetweenScopes = (try? container.decodeIfPresent(Bool.self, forKey: .swipeBetweenScopes)) ?? defaults.swipeBetweenScopes
        showSidebarFooter = (try? container.decodeIfPresent(Bool.self, forKey: .showSidebarFooter)) ?? defaults.showSidebarFooter
        chromeTheme = (try? container.decodeIfPresent(ChromeTheme.self, forKey: .chromeTheme)) ?? defaults.chromeTheme
        showGitActions = (try? container.decodeIfPresent(Bool.self, forKey: .showGitActions)) ?? defaults.showGitActions
        automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation)
        cleanUpAutomatically = (try? container.decodeIfPresent(Bool.self, forKey: .cleanUpAutomatically))
            ?? defaults.cleanUpAutomatically
        notificationsQuoteAgent = (try? container.decodeIfPresent(Bool.self, forKey: .notificationsQuoteAgent))
            ?? defaults.notificationsQuoteAgent
        recordUsage = (try? container.decodeIfPresent(Bool.self, forKey: .recordUsage)) ?? defaults.recordUsage
        archiveMergedTasks = (try? container.decodeIfPresent(Bool.self, forKey: .archiveMergedTasks)) ?? defaults.archiveMergedTasks
        dormantAfterDays = max(0, (try? container.decodeIfPresent(Int.self, forKey: .dormantAfterDays)) ?? defaults.dormantAfterDays)
        followMain = (try? container.decodeIfPresent(FollowMainMode.self, forKey: .followMain)) ?? defaults.followMain
        allowTryInCheckout = (try? container.decodeIfPresent(Bool.self, forKey: .allowTryInCheckout)) ?? defaults.allowTryInCheckout
        showTokenMeter = (try? container.decodeIfPresent(Bool.self, forKey: .showTokenMeter)) ?? defaults.showTokenMeter
        tokenBudgetPer5h = max(0, (try? container.decodeIfPresent(Int.self, forKey: .tokenBudgetPer5h)) ?? defaults.tokenBudgetPer5h)
        showAPICost = (try? container.decodeIfPresent(Bool.self, forKey: .showAPICost)) ?? defaults.showAPICost
        showReturnDigest = (try? container.decodeIfPresent(Bool.self, forKey: .showReturnDigest)) ?? defaults.showReturnDigest
        returnDigestAwayMinutes = min(max((try? container.decodeIfPresent(Int.self, forKey: .returnDigestAwayMinutes))
                                              ?? defaults.returnDigestAwayMinutes, Self.returnDigestAwayRange.lowerBound),
                                      Self.returnDigestAwayRange.upperBound)
        assist = (try? container.decodeIfPresent(AssistMode.self, forKey: .assist)) ?? defaults.assist
        assistDailyCap = min(max((try? container.decodeIfPresent(Int.self, forKey: .assistDailyCap)) ?? defaults.assistDailyCap,
                                 Self.assistDailyCapRange.lowerBound), Self.assistDailyCapRange.upperBound)
        assistQuietsInformational = (try? container.decodeIfPresent(Bool.self, forKey: .assistQuietsInformational))
            ?? defaults.assistQuietsInformational
        assistPicksTopic = (try? container.decodeIfPresent(Bool.self, forKey: .assistPicksTopic)) ?? defaults.assistPicksTopic
        assistSuggestsArchive = (try? container.decodeIfPresent(Bool.self, forKey: .assistSuggestsArchive))
            ?? defaults.assistSuggestsArchive
        // A chord is a key the user may have turned off: an explicit `null` stays `nil`, a missing key is the default,
        // and a chord that does not decode is dropped rather than failing the whole document.
        quickPanelHotkey = container.contains(.quickPanelHotkey)
            ? (try? container.decodeIfPresent(KeyChord.self, forKey: .quickPanelHotkey)) ?? nil
            : defaults.quickPanelHotkey
        toggleWindowHotkey = container.contains(.toggleWindowHotkey)
            ? (try? container.decodeIfPresent(KeyChord.self, forKey: .toggleWindowHotkey)) ?? nil
            : defaults.toggleWindowHotkey
        quickPanelLanding = (try? container.decodeIfPresent(QuickPanel.Landing.self, forKey: .quickPanelLanding))
            ?? defaults.quickPanelLanding
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
