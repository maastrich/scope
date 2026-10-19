import AppKit
import ScopeCore
import SwiftUI

/// Hold ⌘ alone for half a second and every control with a shortcut shows it in a keycap beside itself; let go and
/// the keycaps vanish (spec §7). The chords themselves are untouched: a key pressed while the hints show reaches the
/// menu bar, the terminal or the list exactly as it would have.
///
/// What a keycap says comes from the main menu, read fresh each time the hints come up: the key equivalents AppKit
/// fires, under the ids the usage log counts them by (`UsageMenuTracker.commandID`), so a hint can never name a chord
/// the menu does not have, and one that changes with the state (⇧⌘T) says what it is right now. Keys the menu does
/// not own — `j`/`k` in the Delta, ⌥↩ on a thread row, Esc on the reading column — are declared where they are drawn.
///
/// The events come from a local monitor that returns every one unchanged: the detector only watches. A terminal that
/// needs ⌘ (a ⌘-click on a link, ⌘C) is served first and the hold is simply cancelled.
@MainActor
@Observable
final class CommandKeyHints {
    static let shared = CommandKeyHints()

    /// True while the keycaps are on screen.
    private(set) var isShown = false
    /// Settings ▸ General ▸ Appearance; set by the model from the preference.
    var isEnabled = true {
        didSet { if !isEnabled { apply(detector.interrupted()) } }
    }

    private var detector = CommandHoldDetector()
    private var index = KeyHintIndex()
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var timer: DispatchWorkItem?

    /// `commandKeyHintsDelay` in the app's defaults (`defaults write dev.maastrich.scope commandKeyHintsDelay 0.3`);
    /// not a setting the window shows.
    static var delay: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: "commandKeyHintsDelay") as? Double
        guard let stored else { return CommandHoldDetector.defaultDelay }
        return min(max(stored, CommandHoldDetector.delayRange.lowerBound), CommandHoldDetector.delayRange.upperBound)
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            // Plain values only cross into the isolated closure; the monitor already runs on the main thread.
            let type = event.type
            let modifiers = Self.modifiers(event.modifierFlags)
            MainActor.assumeIsolated { CommandKeyHints.shared.handle(type, modifiers: modifiers) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { CommandKeyHints.shared.apply(CommandKeyHints.shared.detector.interrupted()) }
        }
        #if DEBUG
        // `SCOPE_KEY_HINTS=1` keeps the hints up from launch: a throwaway instance driven from a terminal has no hand on ⌘.
        if ProcessInfo.processInfo.environment["SCOPE_KEY_HINTS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { CommandKeyHints.shared.show() }
        }
        #endif
    }

    /// The keys of the command `id` fires (`command.new-thread`), or `nil` while the hints are hidden or the menu
    /// has no enabled item for it.
    func keys(for id: String) -> String? {
        guard isShown else { return nil }
        return index.keys(for: id)
    }

    // MARK: Events

    private func handle(_ type: NSEvent.EventType, modifiers: KeyChord.Modifiers) {
        guard isEnabled else { return }
        switch type {
        case .flagsChanged: apply(detector.modifiersChanged(modifiers, appActive: NSApp.isActive))
        case .keyDown: apply(detector.keyDown())
        default: apply(detector.mouseDown())
        }
    }

    private func apply(_ effect: CommandHoldDetector.Effect) {
        switch effect {
        case .none:
            break
        case .arm(let generation):
            timer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                apply(detector.delayElapsed(generation: generation))
            }
            timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
        case .show:
            show()
        case .hide:
            hide()
        }
    }

    private func show() {
        index = Self.indexMainMenu()
        guard !isShown else { return }
        isShown = true
        // Counted as a view with how long it stayed up, under the one id: what says whether the hints change how
        // much of the app is reached from the keyboard.
        Usage.opened("hints.shown", label: "Shortcut hints (⌘ held)")
    }

    private func hide() {
        timer?.cancel()
        guard isShown else { return }
        isShown = false
        Usage.closed("hints.shown", source: .keyboard)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyChord.Modifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyChord.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    // MARK: The menu

    /// Every enabled key equivalent of the main menu, under its command id. SwiftUI fills a command menu when it is
    /// about to open, so each submenu is asked to update first — the same walk `UsageMenuTracker` makes.
    private static func indexMainMenu() -> KeyHintIndex {
        guard let menu = NSApp.mainMenu else { return KeyHintIndex() }
        var entries: [KeyHintIndex.Entry] = []
        func walk(_ menu: NSMenu) {
            for (position, item) in menu.items.enumerated() {
                if let submenu = item.submenu {
                    submenu.delegate?.menuNeedsUpdate?(submenu)
                    walk(submenu)
                    continue
                }
                let mask = modifiers(item.keyEquivalentModifierMask)
                guard let keys = KeyEquivalentText.describe(key: item.keyEquivalent, modifiers: mask) else { continue }
                if let (numbered, number) = numberedID(item, position: position) {
                    // By the digit, not the key equivalent: SwiftUI maps ⌘1 to the key the layout puts there (⌘& on
                    // an AZERTY), which is what the menu bar draws and what nobody says aloud.
                    entries.append(.init(id: numbered, keys: mask.description + String(number), enabled: item.isEnabled))
                }
                if let id = UsageMenuTracker.commandID(item) {
                    entries.append(.init(id: id, keys: keys, enabled: item.isEnabled))
                }
            }
        }
        walk(menu)
        return KeyHintIndex(entries: entries)
    }

    /// Thread ▸ Thread N and Go ▸ Scope ▸ <name>, which the usage log folds into one id each: a row needs its own.
    private static func numberedID(_ item: NSMenuItem, position: Int) -> (id: String, number: Int)? {
        if item.parent?.title == "Scope", item.parent?.menu !== NSApp.mainMenu {
            return (KeyHintIndex.scopeID(position + 1), position + 1)
        }
        if item.title.hasPrefix("Thread "), let number = Int(item.title.dropFirst("Thread ".count)) {
            return (KeyHintIndex.threadID(number), number)
        }
        return nil
    }
}

// MARK: - Drawing

/// The keycap a hint is drawn in: small, opaque, on the elevated surface so it reads on the sidebar, a panel band and
/// the toolbar alike, in light and dark.
struct Keycap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Surface.stroke))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Draws the keycap over a control, in an overlay so the layout never moves, and fades it with the hold — or cuts
/// it in and out under Reduce Motion.
private struct KeyHintModifier: ViewModifier {
    /// Read while the hints show, so a hint that depends on the state (⇧⌘T, the thread's number) is current. One
    /// keycap per string; empty shows nothing.
    let keys: () -> [String]
    let alignment: Alignment
    let offset: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let hints = CommandKeyHints.shared
        content
            .overlay(alignment: alignment) {
                if hints.isShown {
                    let keys = keys()
                    if !keys.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(keys, id: \.self) { Keycap(keys: $0) }
                        }
                        .offset(offset)
                        .allowsHitTesting(false)
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hints.isShown)
    }
}

/// Where a keycap sits on a control. `.corner` hangs off the top-right corner, for a button with room around it;
/// `.inside` sits on the trailing edge, for a toolbar item or a row the window would clip at its corner.
enum KeyHintPlacement {
    case corner
    case inside
    /// Inside the control, against its trailing edge: a wide button whose label leaves room there.
    case trailing
    /// Over the middle of the control: a small tile the keycap may cover while it shows.
    case over
    /// Along the leading edge, after the control, for a label with space to its right.
    case after
    case custom(Alignment, CGSize)

    var alignment: Alignment {
        switch self {
        case .corner: .topTrailing
        case .inside, .trailing: .trailing
        case .over: .center
        case .after: .leading
        case .custom(let alignment, _): alignment
        }
    }

    var offset: CGSize {
        switch self {
        case .corner: CGSize(width: 6, height: -6)
        case .inside: CGSize(width: 2, height: 0)
        case .trailing: CGSize(width: -4, height: 0)
        case .over: .zero
        case .after: CGSize(width: 4, height: 0)
        case .custom(_, let offset): offset
        }
    }
}

extension View {
    /// The keys of the menu command this control fires, by its usage id (`command.new-thread`), while ⌘ is held.
    func commandKeyHint(_ command: String, _ placement: KeyHintPlacement = .corner) -> some View {
        modifier(KeyHintModifier(keys: { CommandKeyHints.shared.keys(for: command).map { [$0] } ?? [] },
                                 alignment: placement.alignment, offset: placement.offset))
    }

    /// Keys resolved while ⌘ is held: menu commands by id through `CommandKeyHints.keys(for:)`, keys the menu does not
    /// own (`j / k`, `⌥↩`, `⎋`) as given. One keycap per string.
    func keyHints(_ placement: KeyHintPlacement = .corner, _ keys: @escaping () -> [String]) -> some View {
        modifier(KeyHintModifier(keys: keys, alignment: placement.alignment, offset: placement.offset))
    }

    /// A key the menu does not own, shown as given while ⌘ is held.
    func keyHint(_ keys: String, _ placement: KeyHintPlacement = .corner) -> some View {
        modifier(KeyHintModifier(keys: { [keys] }, alignment: placement.alignment, offset: placement.offset))
    }
}
