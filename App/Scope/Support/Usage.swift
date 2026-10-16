import AppKit
import ScopeCore
import SwiftUI

/// The app's side of the usage log: what the controls, the menus, the palette and the model call when the user does
/// something. Everything ends in `UsageRecorder.record`, which only enqueues — nothing here touches the disk.
///
/// Ids follow `UsageEvent.id`: `<area>.<element>`. The area comes from where a control is drawn (`.usageArea`), the
/// element from an explicit `.usageID` or from what the control knows about itself (a picker's label, a symbol);
/// a button that has neither is counted as `<area>.button`, so the area is right even when the button is unnamed.
@MainActor
enum Usage {
    /// Set by the app model once the environment exists; `nil` in previews.
    static var recorder: UsageRecorder?
    /// The scope the user is in, logged as its UUID.
    static var currentScope: () -> String? = { nil }
    /// Ids already sent to the registry this launch, so a redraw costs a set lookup.
    private static var registered: Set<String> = []
    /// Views on screen, by id, with when they appeared.
    private static var shown: [String: Date] = [:]
    /// Set while a palette row or a notification runs its action: the selection it changes is theirs, not a click.
    static var attributing = false

    static func record(_ kind: UsageEvent.Kind, _ id: String, source: UsageEvent.Source, context: String? = nil,
                       duration: Double? = nil) {
        recorder?.record(UsageEvent(kind: kind, id: id, source: source, scope: currentScope(), context: context,
                                    duration: duration))
    }

    /// A control under the pointer was clicked.
    static func click(_ id: String, label: String? = nil) {
        register(id, label: label)
        record(.click, id, source: .mouse)
    }

    /// Adds an element to the registry the first time it is seen this launch.
    static func register(_ id: String, label: String?) {
        guard registered.insert(id).inserted else { return }
        recorder?.register([UsageElement(id: id, label: label ?? id)])
    }

    static func register(_ elements: [UsageElement]) {
        let fresh = elements.filter { registered.insert($0.id).inserted }
        recorder?.register(fresh)
    }

    // MARK: Views

    static func opened(_ id: String, label: String? = nil) {
        register(id, label: label)
        if shown[id] == nil { shown[id] = .now }
    }

    static func closed(_ id: String, source: UsageEvent.Source = .mouse) {
        guard let start = shown.removeValue(forKey: id) else { return }
        record(.view, id, source: source, duration: Date.now.timeIntervalSince(start))
    }

    /// At quit: whatever is still on screen is logged with the time it had.
    static func closeAll() {
        for id in shown.keys.sorted() { closed(id, source: .app) }
    }

    // MARK: Where an event came from

    /// What the event AppKit is handling says about the gesture: a key, the pointer, or neither (a timer, a socket).
    static var currentInput: UsageEvent.Source? {
        switch NSApp.currentEvent?.type {
        case .keyDown, .keyUp: .keyboard
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseUp: .mouse
        default: nil
        }
    }

    /// Runs `action` with `attributing` set, so the selection it changes is not counted a second time as a click.
    static func attributed(_ action: () -> Void) {
        let before = attributing
        attributing = true
        defer { attributing = before }
        action()
    }
}

// MARK: - Menu commands

/// Counts menu bar commands, by key equivalent or by pointer, from the one notification every `NSMenuItem` posts —
/// so `ScopeCommands` stays as it is. Only the main menu: a context or pop-up menu's items carry thread names,
/// branches and paths, which cannot be logged.
@MainActor
enum UsageMenuTracker {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil,
                                                          queue: .main) { note in
            // Posted on the main thread while AppKit still handles the event that picked the item, so the current
            // event says whether it was a key equivalent.
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                let keyboard = NSApp.currentEvent?.type == .keyDown
                guard let item = note.userInfo?["MenuItem"] as? NSMenuItem, let id = commandID(item) else { return }
                Usage.register(id, label: label(item))
                Usage.record(keyboard ? .shortcut : .menu, id, source: keyboard ? .keyboard : .menu)
            }
        }
        // SwiftUI fills the menu bar after launch; the registry learns its commands once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { registerMainMenu() }
    }

    /// Every command of the menu bar, so one never chosen still shows up as never used.
    static func registerMainMenu() {
        guard let menu = NSApp.mainMenu else { return }
        var elements: [UsageElement] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu {
                    // SwiftUI fills a command menu when it is about to open; asking it to now is how its items exist.
                    submenu.delegate?.menuNeedsUpdate?(submenu)
                    walk(submenu)
                } else if let id = commandID(item) {
                    elements.append(UsageElement(id: id, label: label(item)))
                }
            }
        }
        walk(menu)
        Usage.register(elements)
    }

    /// `command.<slug>`, the id the palette logs the same command under; `nil` for anything outside the main menu or
    /// whose title is data (a window's name).
    static func commandID(_ item: NSMenuItem) -> String? {
        // No `action` check: SwiftUI clears it on a disabled item, which is still a command the registry should know.
        guard !item.isSeparatorItem, item.submenu == nil, isInMainMenu(item),
              item.action != #selector(NSWindow.makeKeyAndOrderFront(_:)) else { return nil }
        let parent = item.parent?.title ?? ""
        if systemSubmenus.contains(parent) || systemItems.contains(item.title) { return nil }
        // Items titled with data: a scope's name (Go ▸ Scope), a driver's name (New Thread With Driver).
        // Go ▸ Scope's ⌃1…⌃9, titled with the scopes' names — told apart from the application menu, which is called
        // Scope too, by being nested rather than in the menu bar itself.
        if parent == "Scope", item.parent?.menu !== NSApp.mainMenu { return "command.select-scope-by-number" }
        if parent == "New Thread With Driver" { return "command.new-thread-with-driver" }
        let slug = UsageID.slug(item.title)
        guard !slug.isEmpty else { return nil }
        if slug.hasPrefix("thread-"), Int(slug.dropFirst("thread-".count)) != nil { return "command.select-thread-by-number" }
        return "command." + (aliases[slug] ?? slug)
    }

    private static func label(_ item: NSMenuItem) -> String {
        let parent = item.parent?.title ?? ""
        if parent == "New Thread With Driver" { return "New Thread With Driver" }
        if commandID(item) == "command.select-scope-by-number" { return "Go to Scope 1…9" }
        if commandID(item) == "command.select-thread-by-number" { return "Go to Thread 1…9" }
        return item.title.replacingOccurrences(of: "…", with: "")
    }

    private static func isInMainMenu(_ item: NSMenuItem) -> Bool {
        var menu = item.menu
        while let current = menu {
            if current === NSApp.mainMenu { return true }
            menu = current.supermenu
        }
        return false
    }

    /// What macOS adds to every app's menus: not Scope's to count.
    static let systemSubmenus: Set<String> = ["Writing Tools", "AutoFill", "Services", "Speech", "Substitutions",
                                              "Transformations", "Spelling and Grammar", "Font", "Text"]
    static let systemItems: Set<String> = ["Start Dictation…", "Emoji & Symbols", "Show Writing Tools"]

    /// Menu titles whose slug differs from the palette id of the same command, and titles that flip with state
    /// (Show / Hide Sidebar), so that one command is one id whichever way it was reached.
    static let aliases: [String: String] = [
        "refresh-scope": "refresh",
        "stop": "stop-thread",
        "relaunch": "relaunch-thread",
        "undo-close-thread": "undo-close",
        "go-to-file": "find-files",
        "go-to-file-open-quickly": "find-files",
        "analyze-graph": "analyze",
        "graph": "show-graph",
        "pull-requests": "show-prs",
        "mark-as-read": "mark-read",
        "maximize-thread": "maximize",
        "restore-thread": "maximize",
        "show-sidebar": "sidebar",
        "hide-sidebar": "sidebar",
        "toggle-inspector": "inspector",
        "keyboard-shortcuts": "shortcuts",
        "check-for-updates": "updates",
        "declare-a-scope": "declare",
        "archive-task": "task-archive",
        "open-task-in-editor": "editor-task",
        "show-repositories": "repositories",
        "hide-repositories": "repositories",
        "detailed-rows": "sidebar-rows",
        "compact-rows": "sidebar-rows",
        "arrange-as-a-tree": "sidebar-arrangement",
        "arrange-by-state": "sidebar-arrangement",
    ]
}

// MARK: - Where a control is drawn

private struct UsageAreaKey: EnvironmentKey {
    static let defaultValue = "app"
}

private struct UsageIDKey: EnvironmentKey {
    static let defaultValue: UsageTag? = nil
}

/// An explicit id for one control, with the label the report shows for it.
struct UsageTag: Equatable {
    var id: String
    var label: String?
}

extension EnvironmentValues {
    /// The area the controls below are counted in (`sidebar`, `inspector.delta`, `sheet.graph`).
    var usageArea: String {
        get { self[UsageAreaKey.self] }
        set { self[UsageAreaKey.self] = newValue }
    }

    /// The id of the one control this is applied to. Never set on a container: every control inside would take it.
    var usageTag: UsageTag? {
        get { self[UsageIDKey.self] }
        set { self[UsageIDKey.self] = newValue }
    }
}

extension Usage {
    /// What a click on a control is logged as: its own id under the area, or the area's unnamed bucket.
    static func id(area: String, tag: UsageTag?, fallback element: String) -> (id: String, label: String?) {
        guard let tag else { return (UsageID.join(area, element), nil) }
        return (tag.id.contains(".") ? tag.id : UsageID.join(area, tag.id), tag.label)
    }
}

extension View {
    /// Counts the controls below in `area`. A nested area replaces the outer one.
    func usageArea(_ area: String) -> some View {
        environment(\.usageArea, area).environment(\.usageTag, nil)
    }

    /// Names one control for the usage log: `element` under the area it is drawn in, or a full id when it holds a dot.
    func usageID(_ element: String, label: String? = nil) -> some View {
        environment(\.usageTag, UsageTag(id: element, label: label))
    }

    /// A surface whose time on screen is counted (a sheet, a panel), and the area of the controls on it.
    func usageSurface(_ id: String, label: String) -> some View {
        usageArea(id)
            .onAppear { Usage.opened(id, label: label) }
            .onDisappear { Usage.closed(id) }
    }
}

/// Logs a click when a button style's press ends with the pointer still on it — a `ButtonStyle` sees the press but not
/// the action, and a press released elsewhere is a cancel. Registers the control the first time it is drawn.
struct UsageClickTracker: ViewModifier {
    let isPressed: Bool
    let hovering: Bool
    let fallback: String
    @Environment(\.usageArea) private var area
    @Environment(\.usageTag) private var tag

    func body(content: Content) -> some View {
        let (id, label) = Usage.id(area: area, tag: tag, fallback: fallback)
        content
            .onAppear { Usage.register(id, label: label) }
            .onChange(of: isPressed) { wasPressed, pressed in
                if wasPressed, !pressed, hovering { Usage.click(id, label: label) }
            }
    }
}

extension View {
    func usageClicks(pressed: Bool, hovering: Bool, fallback: String = "button") -> some View {
        modifier(UsageClickTracker(isPressed: pressed, hovering: hovering, fallback: fallback))
    }
}
