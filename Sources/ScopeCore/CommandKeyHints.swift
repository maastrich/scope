import Foundation

/// The shortcut hints (spec §7): hold ⌘ on its own for a moment and every control that has a shortcut shows it in a
/// small keycap beside itself, the way iPadOS and Office do. The decisions that need no window live here: when the
/// hold counts (`CommandHoldDetector`), how a menu's key equivalent reads (`KeyEquivalentText`), and which keys a
/// control ends up with (`KeyHintIndex`). The app feeds the detector its events and draws the keycaps.

/// Decides when the hints show and when they go, from the modifier and key events the app sees.
///
/// ⌘ pressed alone *arms* the detector; the app starts a timer for `delay`. Any key, click or other modifier before
/// the timer fires disarms it, so ⌘C or a ⌘-click never flashes the hints. Once shown, the hints stay while ⌘ is down,
/// whatever else is pressed with it — the chord a hint names is typed with ⌘ still held — and go when ⌘ goes up, or
/// when the app stops being active. A timer is numbered by its generation so one left over from a cancelled hold can
/// never show the hints.
public struct CommandHoldDetector: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// ⌘ is down alone; the timer of this generation is running.
        case armed(generation: Int)
        case shown
    }

    /// What the app does in answer to an event.
    public enum Effect: Sendable, Equatable {
        case none
        /// Start the timer; call `delayElapsed` with the same generation when it fires.
        case arm(generation: Int)
        case show
        case hide
    }

    /// How long ⌘ is held alone before the hints show. Long enough that a chord typed at speed never trips it,
    /// short enough to feel like asking.
    public static let defaultDelay: TimeInterval = 0.5
    /// The internal setting (`commandKeyHintsDelay` in the app's defaults) is kept to this range.
    public static let delayRange: ClosedRange<TimeInterval> = 0.15...3

    public private(set) var phase: Phase = .idle
    private var generation = 0

    public init() {}

    public var isShown: Bool { phase == .shown }

    /// The modifiers now down, after a `flagsChanged` event.
    public mutating func modifiersChanged(_ modifiers: KeyChord.Modifiers, appActive: Bool = true) -> Effect {
        switch phase {
        case .idle:
            guard modifiers == [.command], appActive else { return .none }
            generation += 1
            phase = .armed(generation: generation)
            return .arm(generation: generation)
        case .armed:
            // ⌘ alone again is the same hold (a repeat); anything else — ⌘ gone, or a second modifier joining
            // for a chord — ends it.
            if modifiers == [.command] { return .none }
            phase = .idle
            return .none
        case .shown:
            if modifiers.contains(.command) { return .none }
            phase = .idle
            return .hide
        }
    }

    /// The timer of `generation` fired.
    public mutating func delayElapsed(generation: Int) -> Effect {
        guard case .armed(let armed) = phase, armed == generation else { return .none }
        phase = .shown
        return .show
    }

    /// A key went down. Before the delay the user is typing a chord: not a hold. While shown, the chord is the
    /// one the hint named — the hints stay until ⌘ goes up.
    public mutating func keyDown() -> Effect {
        cancelIfArmed()
    }

    /// A mouse button went down: a ⌘-click (a link in the terminal, a multiple selection) is not a hold.
    public mutating func mouseDown() -> Effect {
        cancelIfArmed()
    }

    /// The app went to the background, or the hints were switched off: nothing may stay or come up.
    public mutating func interrupted() -> Effect {
        let effect: Effect = phase == .shown ? .hide : .none
        phase = .idle
        return effect
    }

    private mutating func cancelIfArmed() -> Effect {
        if case .armed = phase { phase = .idle }
        return .none
    }
}

/// How a menu item's key equivalent reads in a keycap: `⇧⌘N`, `⌥⌘↩`, `⌃1`.
public enum KeyEquivalentText {
    /// The glyph for a key AppKit names with a control or a function character; a printable key is itself, in capitals.
    private static let glyphs: [String: String] = [
        "\r": "↩", "\n": "↩", "\u{3}": "⌤", "\t": "⇥", "\u{19}": "⇤", "\u{1b}": "⎋", " ": "Space",
        "\u{8}": "⌫", "\u{7f}": "⌫", "\u{F728}": "⌦",
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
        "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟",
    ]

    /// `nil` for an item without a key equivalent. A capital letter as the key means ⇧, the AppKit convention.
    public static func describe(key: String, modifiers: KeyChord.Modifiers) -> String? {
        guard !key.isEmpty else { return nil }
        var modifiers = modifiers
        let name: String
        if let glyph = glyphs[key] {
            name = glyph
        } else if key.count == 1, key.unicodeScalars.first.map({ CharacterSet.uppercaseLetters.contains($0) }) == true {
            modifiers.insert(.shift)
            name = key
        } else {
            name = key.uppercased()
        }
        return modifiers.description + name
    }
}

/// Which keys each control shows, by the id of the command it fires — the id the usage log counts the command
/// under (`command.new-thread`), so a hint can never name a command the menu bar does not have.
///
/// The app rebuilds it from the main menu every time the hints come up: the menu is what AppKit fires, so a hint
/// cannot drift from it, and an item whose shortcut changes with the state (⇧⌘T is New Task… or Undo Close Thread)
/// shows what it is right now. A disabled item has no hint: the chord would do nothing.
public struct KeyHintIndex: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var keys: String
        public var enabled: Bool

        public init(id: String, keys: String, enabled: Bool = true) {
            self.id = id
            self.keys = keys
            self.enabled = enabled
        }
    }

    private var keys: [String: String] = [:]

    public init() {}

    /// The first entry for an id wins: two items firing one command (Go to File… and its Open Quickly alias) show
    /// the one listed first in the menus.
    public init(entries: [Entry]) {
        for entry in entries where entry.enabled && keys[entry.id] == nil {
            keys[entry.id] = entry.keys
        }
    }

    public var isEmpty: Bool { keys.isEmpty }

    public func keys(for id: String) -> String? {
        keys[id]
    }

    /// The id of "Thread N" (⌘1…⌘9) and of the Nth scope of Go ▸ Scope (⌃1…⌃9), `number` counted from 1.
    public static func threadID(_ number: Int) -> String { "command.thread-\(number)" }
    public static func scopeID(_ number: Int) -> String { "command.scope-\(number)" }
}
