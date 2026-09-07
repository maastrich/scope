import AppKit
import ScopeCore
import SwiftTerm

/// Terminal colours: a light and a dark palette, picked from `NSAppearance` (or forced dark by the
/// `terminalAppearance` preference) and re-applied live by `TerminalHostContainer` when either changes.
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

    /// `#1e1e21` on `#e6e6ea`.
    static let dark = Palette(
        background: rgb(0x1e1e21),
        foreground: rgb(0xe6e6ea),
        selection: asset("TerminalSelectionDark", fallback: 0x44475a),
        ansi: [0x1e1e21, 0xff5f5f, 0x5fd75f, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xc8c8cc,
               0x6c6c73, 0xff8787, 0x87e787, 0xf2d58c, 0x82c4ff, 0xd7a3ee, 0x7fd5e0, 0xffffff].map(ansi),
        isDark: true)

    /// `#ffffff` on `#1d1d1f`, ANSI colours darkened for a white ground (bright red / yellow / magenta / cyan
    /// reuse the normal values: the "bright" ones drop below 4:1 on white).
    static let light = Palette(
        background: rgb(0xffffff),
        foreground: rgb(0x1d1d1f),
        selection: asset("TerminalSelectionLight", fallback: 0x9cc7ff),
        ansi: [0x1d1d1f, 0xc41a16, 0x1a7f37, 0x9a6700, 0x0550ae, 0x8250df, 0x0e7c86, 0x8e8e93,
               0x6e6e73, 0xcf222e, 0x2da44e, 0x9a6700, 0x2f81f7, 0x8250df, 0x0e7c86, 0x1d1d1f].map(ansi),
        isDark: false)

    // MARK: Preferences

    /// `system` follows the appearance, `alwaysDark` forces the dark palette and ground.
    private(set) static var mode: TerminalAppearanceMode = .system
    private(set) static var fontSize: CGFloat = 13

    /// Records the terminal preferences; returns `true` when something changed (callers then re-apply).
    @discardableResult
    static func configure(_ preferences: Preferences) -> Bool {
        let size = CGFloat(Preferences.clampTerminalFontSize(preferences.terminalFontSize))
        let changed = size != fontSize || preferences.terminalAppearance != mode
        fontSize = size
        mode = preferences.terminalAppearance
        return changed
    }

    /// The palette for a given appearance (defaults to the app's effective appearance); always `dark` under
    /// the `alwaysDark` preference.
    static func palette(for appearance: NSAppearance? = nil) -> Palette {
        if mode == .alwaysDark { return dark }
        let appearance = appearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? dark : light
    }

    /// A dynamic background colour, for SwiftUI/AppKit surfaces that must match the terminal ground.
    static let background = NSColor(name: nil) { appearance in
        palette(for: appearance).background
    }

    /// Space between the pane edges and the first cell (UI direction A: pane body padding `12 14`).
    static let contentInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

    /// The frame a terminal is created with, before its host lays it out (about 90×28 cells at 13 pt).
    static let initialFrame = NSRect(x: 0, y: 0, width: 800, height: 480)

    /// Emulator options read once at init: 10 000 lines of scrollback.
    static var options: TerminalOptions {
        TerminalOptions(scrollback: 10_000)
    }

    /// SF Mono at the preferred size, falling back to the system monospaced font.
    static var font: NSFont { font(size: fontSize) }

    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "SFMono-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Applies colours, font and input behaviour to a freshly created view.
    static func apply(to view: LocalProcessTerminalView) {
        applyFont(to: view)
        view.optionAsMetaKey = true
        view.bellStyle = .visual
        applyColors(to: view)
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

    private nonisolated static func ansi(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16) & 0xff) * 257,
                        green: UInt16((hex >> 8) & 0xff) * 257,
                        blue: UInt16(hex & 0xff) * 257)
    }
}
