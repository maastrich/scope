import AppKit
import ScopeCore
import SwiftTerm

/// Terminal colours: a light and a dark palette built from the system colours of each appearance, picked from
/// `NSAppearance` (or forced dark by the `terminalAppearance` preference) and re-applied live by
/// `TerminalHostContainer` when either changes.
/// `ThreadPane` pushes the preferences here before the host is built (`configure(_:)`).
@MainActor
enum TerminalAppearance {
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let selection: NSColor
        /// The 16 ANSI colours (normal 0–7, bright 8–15).
        let ansi: [SwiftTerm.Color]
        /// Drives the colour scheme of the overlays drawn on the terminal (`ThreadBanner`).
        let isDark: Bool
    }

    /// The two palettes, built once each from the system colours of their appearance (`build(dark:)`).
    private static var cache: [Bool: Palette] = [:]

    /// The palette of one appearance, from the colours the rest of the window is drawn with, so the terminal
    /// reads as part of the app rather than as a black box set into it: the ground is the window background,
    /// the text the label colour, and the sixteen ANSI colours the system's red, green, yellow, blue, purple
    /// and teal — the sober hues macOS uses everywhere — resolved for that appearance. The bright eight are the
    /// same hues lifted a little in the dark, and the normal ones again on white, where a brighter red or
    /// yellow would only lose contrast. Programs that colour with the ANSI set (Claude Code on its `-ansi`
    /// theme, ls, git) then look like the app; the ones that bring their own true colour are untouched.
    private static func build(dark: Bool) -> Palette {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var palette: Palette?
        appearance.performAsCurrentDrawingAppearance {
            let background = resolve(.windowBackgroundColor, over: nil)
            let foreground = resolve(.labelColor, over: background)
            let secondary = resolve(.secondaryLabelColor, over: background)
            let tertiary = resolve(.tertiaryLabelColor, over: background)
            let red = resolve(.systemRed, over: background)
            let green = resolve(.systemGreen, over: background)
            // System yellow is a warning colour, not a text colour: on white it needs darkening to be read.
            let yellow = dark ? resolve(.systemYellow, over: background) : mix(resolve(.systemYellow, over: background), with: .black, 0.38)
            let blue = resolve(.systemBlue, over: background)
            let magenta = resolve(.systemPurple, over: background)
            let cyan = resolve(.systemTeal, over: background)
            // Black is a shade darker than the ground in the dark, so a black-on-default run still shows.
            let black = dark ? mix(background, with: .black, 0.45) : foreground
            // On white, the two whites are the light greys of a classic light terminal, a step below the
            // ground, not text colours: programs use them as *backgrounds* there. Claude Code's `light-ansi`
            // theme paints the user's prompt on `white` and expanded tool output on `whiteBright`, and writes
            // `black` over both; a grey `white` and a near-black `whiteBright` gave dark blocks in light mode.
            let white = dark ? secondary : mix(background, with: .black, 0.16)
            let whiteBright = dark ? foreground : mix(background, with: .black, 0.07)
            let lift: (NSColor) -> NSColor = { dark ? mix($0, with: .white, 0.18) : $0 }
            let normal = [black, red, green, yellow, blue, magenta, cyan, white]
            let bright = [dark ? tertiary : secondary, lift(red), lift(green), lift(yellow), lift(blue), lift(magenta), lift(cyan), whiteBright]
            palette = Palette(
                background: background,
                foreground: foreground,
                selection: asset(dark ? "TerminalSelectionDark" : "TerminalSelectionLight", fallback: dark ? 0x44475a : 0x9cc7ff),
                ansi: (normal + bright).map(ansi),
                isDark: dark)
        }
        return palette ?? Palette(background: rgb(dark ? 0x1e1e21 : 0xffffff), foreground: rgb(dark ? 0xe6e6ea : 0x1d1d1f),
                                  selection: rgb(dark ? 0x44475a : 0x9cc7ff), ansi: [], isDark: dark)
    }

    /// The colour as sRGB under the current drawing appearance, its alpha composited over `ground` (label
    /// colours are translucent; a terminal wants opaque cells).
    private static func resolve(_ color: NSColor, over ground: NSColor?) -> NSColor {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        guard let ground, srgb.alphaComponent < 1 else { return srgb.withAlphaComponent(1) }
        return mix(ground, with: srgb.withAlphaComponent(1), srgb.alphaComponent)
    }

    /// `base` moved `fraction` of the way to `other`, in sRGB.
    private static func mix(_ base: NSColor, with other: NSColor, _ fraction: CGFloat) -> NSColor {
        let a = base.usingColorSpace(.sRGB) ?? base
        let b = other.usingColorSpace(.sRGB) ?? other
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * fraction,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
                       alpha: 1)
    }

    // MARK: Preferences

    /// `system` follows the appearance, `alwaysDark` forces the dark palette and ground.
    private(set) static var mode: TerminalAppearanceMode = .system
    private(set) static var fontSize: CGFloat = 13
    /// Shape of the caret (Settings ▸ Terminal); the default is steady, see `TerminalCursorStyle`.
    private(set) static var cursorStyle: TerminalCursorStyle = .steadyUnderline
    /// Whether ⌥ is the Meta key rather than a way to type a character. Off by default — see
    /// `Preferences.terminalOptionAsMeta`.
    private(set) static var optionAsMeta = false

    /// Records the terminal preferences; returns `true` when something changed (callers then re-apply).
    @discardableResult
    static func configure(_ preferences: Preferences) -> Bool {
        let size = CGFloat(Preferences.clampTerminalFontSize(preferences.terminalFontSize))
        let changed = size != fontSize || preferences.terminalAppearance != mode
            || preferences.terminalCursorStyle != cursorStyle
            || preferences.terminalOptionAsMeta != optionAsMeta
        fontSize = size
        mode = preferences.terminalAppearance
        cursorStyle = preferences.terminalCursorStyle
        optionAsMeta = preferences.terminalOptionAsMeta
        return changed
    }

    /// The palette for a given appearance (defaults to the app's effective appearance); always `dark` under
    /// the `alwaysDark` preference.
    static func palette(for appearance: NSAppearance? = nil) -> Palette {
        let isDark: Bool
        if mode == .alwaysDark {
            isDark = true
        } else {
            let appearance = appearance ?? NSApp.effectiveAppearance
            isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        if let cached = cache[isDark] { return cached }
        let built = build(dark: isDark)
        cache[isDark] = built
        return built
    }

    /// A dynamic background colour, for SwiftUI/AppKit surfaces that must match the terminal ground.
    static let background = NSColor(name: nil) { appearance in
        palette(for: appearance).background
    }

    /// Space between the pane edges and the first cell (UI direction A: pane body padding `12 14`).
    static let contentInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

    /// The frame a terminal is created with, before its host lays it out (about 90×28 cells at 13 pt).
    static let initialFrame = NSRect(x: 0, y: 0, width: 800, height: 480)

    /// Emulator options read once at init: 10 000 lines of scrollback and the caret of the preferences.
    static var options: TerminalOptions {
        TerminalOptions(cursorStyle: swiftTermCursorStyle, scrollback: 10_000)
    }

    /// The preference as SwiftTerm spells it.
    static var swiftTermCursorStyle: CursorStyle {
        switch cursorStyle {
        case .steadyUnderline: .steadyUnderline
        case .blinkUnderline: .blinkUnderline
        case .steadyBar: .steadyBar
        case .blinkBar: .blinkBar
        case .steadyBlock: .steadyBlock
        case .blinkBlock: .blinkBlock
        }
    }

    /// Puts the preferred caret back on a live terminal. A program can ask for another shape at runtime
    /// (`DECSCUSR`) and keep it; this is what every terminal returns to when the preference changes.
    static func applyCursorStyle(to view: LocalProcessTerminalView) {
        view.getTerminal().setCursorStyle(swiftTermCursorStyle)
    }

    /// SF Mono at the preferred size, falling back to the system monospaced font.
    static var font: NSFont { font(size: fontSize) }

    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "SFMono-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Applies colours, font and input behaviour to a freshly created view.
    static func apply(to view: LocalProcessTerminalView) {
        applyFont(to: view)
        applyCursorStyle(to: view)
        applyOptionKey(to: view)
        view.bellStyle = .visual
        applyColors(to: view)
    }

    /// Hands ⌥ to SwiftTerm as Meta, or to macOS as a way to compose a character. SwiftTerm reads the key
    /// *ignoring modifiers* when ⌥ is Meta, so with it on `⌥)` sends `ESC )` and the `}` it should have
    /// typed never exists.
    static func applyOptionKey(to view: LocalProcessTerminalView) {
        view.optionAsMetaKey = optionAsMeta
    }

    /// Sets the preferred font on a live view (no-op when the size already matches: SwiftTerm re-lays out on set).
    static func applyFont(to view: LocalProcessTerminalView) {
        if view.font.pointSize != fontSize || view.font.fontName != font.fontName {
            view.font = font
        }
    }

    /// Applies the palette of the current (or given) appearance to a live view; safe to call repeatedly.
    static func applyColors(to view: LocalProcessTerminalView, appearance: NSAppearance? = nil) {
        let palette = palette(for: appearance)
        view.nativeBackgroundColor = palette.background
        view.nativeForegroundColor = palette.foreground
        view.caretColor = palette.foreground
        view.caretTextColor = palette.background
        view.selectedTextBackgroundColor = palette.selection
        view.installColors(palette.ansi)
    }

    private nonisolated static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    /// A catalogue colour (so designers tune it next to the UI colours), or the literal when the asset is missing.
    private nonisolated static func asset(_ name: String, fallback hex: UInt32) -> NSColor {
        NSColor(named: name) ?? rgb(hex)
    }

    private static func ansi(_ color: NSColor) -> SwiftTerm.Color {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return SwiftTerm.Color(red: UInt16(max(0, min(1, srgb.redComponent)) * 65535),
                               green: UInt16(max(0, min(1, srgb.greenComponent)) * 65535),
                               blue: UInt16(max(0, min(1, srgb.blueComponent)) * 65535))
    }
}
