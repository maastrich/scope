import AppKit
import SwiftTerm

/// Terminal colours follow the app appearance (which follows the system): a light and a dark palette,
/// picked from `NSAppearance` and re-applied live by `TerminalHostContainer` when the appearance changes.
@MainActor
enum TerminalAppearance {
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let selection: NSColor
        /// The 16 ANSI colours (normal 0–7, bright 8–15).
        let ansi: [SwiftTerm.Color]
    }

    /// `#1e1e21` on `#e6e6ea`.
    static let dark = Palette(
        background: rgb(0x1e1e21),
        foreground: rgb(0xe6e6ea),
        selection: rgb(0x3a3d4b),
        ansi: [0x1e1e21, 0xff5f5f, 0x5fd75f, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xc8c8cc,
               0x6c6c73, 0xff8787, 0x87e787, 0xf2d58c, 0x82c4ff, 0xd7a3ee, 0x7fd5e0, 0xffffff].map(ansi))

    /// `#ffffff` on `#1d1d1f`, ANSI colours darkened for a white ground.
    static let light = Palette(
        background: rgb(0xffffff),
        foreground: rgb(0x1d1d1f),
        selection: rgb(0xb4d5fe),
        ansi: [0x1d1d1f, 0xc41a16, 0x1a7f37, 0x9a6700, 0x0550ae, 0x8250df, 0x0e7c86, 0x8e8e93,
               0x6e6e73, 0xe5484d, 0x2da44e, 0xbf8700, 0x2f81f7, 0xa475f9, 0x1b9aaa, 0x1d1d1f].map(ansi))

    /// The palette for a given appearance (defaults to the app's effective appearance).
    static func palette(for appearance: NSAppearance? = nil) -> Palette {
        let appearance = appearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? dark : light
    }

    /// A dynamic background colour, for SwiftUI/AppKit surfaces that must match the terminal ground.
    static let background = NSColor(name: nil) { appearance in
        palette(for: appearance).background
    }

    static let fontSize: CGFloat = 12
    /// The frame a terminal is created with, before its host lays it out (about 97×30 cells at 12 pt).
    static let initialFrame = NSRect(x: 0, y: 0, width: 800, height: 480)

    /// Emulator options read once at init: 10 000 lines of scrollback.
    static var options: TerminalOptions {
        TerminalOptions(scrollback: 10_000)
    }

    /// SF Mono 12, falling back to the system monospaced font.
    static var font: NSFont {
        NSFont(name: "SFMono-Regular", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Applies colours, font and input behaviour to a freshly created view.
    static func apply(to view: LocalProcessTerminalView) {
        view.font = font
        view.optionAsMetaKey = true
        view.bellStyle = .visual
        applyColors(to: view)
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

    private nonisolated static func ansi(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16((hex >> 16) & 0xff) * 257,
                        green: UInt16((hex >> 8) & 0xff) * 257,
                        blue: UInt16(hex & 0xff) * 257)
    }
}
