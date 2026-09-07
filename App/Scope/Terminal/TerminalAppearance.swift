import AppKit
import SwiftTerm

/// The fixed dark look of every terminal (UI direction A): the terminal never follows the app theme.
@MainActor
enum TerminalAppearance {
    /// `#1e1e21`
    static let background = NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x21 / 255, alpha: 1)
    /// `#e6e6ea`
    static let foreground = NSColor(srgbRed: 0xe6 / 255, green: 0xe6 / 255, blue: 0xea / 255, alpha: 1)
    static let selection = NSColor(srgbRed: 0x3a / 255, green: 0x3d / 255, blue: 0x4b / 255, alpha: 1)

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
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.caretColor = foreground
        view.selectedTextBackgroundColor = selection
        view.optionAsMetaKey = true
        view.bellStyle = .visual
        view.appearance = NSAppearance(named: .darkAqua)
    }
}
