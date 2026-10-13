import AppKit
import SwiftUI
import ScopeCore

/// A scope as a 20 pt square: its logo when it has one, else a letter (or the icon chosen for it) on its tint.
/// The mark at its corner is the most pressing thing happening in the scope (`ScopeActivity`), in the shapes the
/// thread rows already use — a square waits for the user, a diamond failed, a dot is a result to read — plus a
/// ring for agents at work, the quietest of the four and never animated: a row of pulsing tiles would be the
/// loudest thing in the window for the least urgent fact. A scope where nothing happens carries no mark.
struct ScopeTile: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    /// `nil` draws no mark: the current scope's own tile, whose rows are on screen.
    var activity: ScopeActivity?
    var size: CGFloat = 20

    var body: some View {
        face
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let activity, activity != .quiet, activity != .missing {
                    ScopeActivityMark(activity: activity)
                        .offset(x: 3, y: -3)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        if scope.kind == .missing {
            shape.strokeBorder(Ink.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .overlay(Text("?").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(Ink.tertiary))
        } else if let logo = model.scopeLogo(scope) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            shape.fill(ScopeTintStyle.fill(scope.declaration.resolvedTint))
                .overlay(
                    Text(scope.declaration.monogram)
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(ScopeTintStyle.onFill)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                )
        }
    }
}

/// The corner mark of a tile, knocked out of the chrome behind it so it reads on any tint.
struct ScopeActivityMark: View {
    let activity: ScopeActivity
    private let size: CGFloat = 7

    var body: some View {
        mark
            .frame(width: size, height: size)
            .padding(1.5)
            .background(Surface.surface, in: Circle())
    }

    @ViewBuilder
    private var mark: some View {
        switch activity {
        case .waiting: RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(ThreadStateStyle.waiting)
        case .failed: RoundedRectangle(cornerRadius: 1, style: .continuous).fill(ThreadStateStyle.failed)
            .rotationEffect(.degrees(45)).scaleEffect(0.8)
        case .unread: Circle().fill(ThreadStateStyle.done)
        case .working: Circle().strokeBorder(ThreadStateStyle.running, lineWidth: 1.5)
        case .quiet, .missing: EmptyView()
        }
    }
}

/// The eight tile colours. Each fill is ≥ 3:1 against the sidebar ground and ≥ 4.5:1 under its glyph in both
/// appearances (pastel under a near-black glyph in dark, deep under a white one in light).
enum ScopeTintStyle {
    static func fill(_ tint: ScopeTint) -> Color {
        let (dark, light) = values(tint)
        return Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    static let onFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x101010) : .white
    })

    private static func values(_ tint: ScopeTint) -> (dark: Int, light: Int) {
        switch tint {
        case .violet: (0xB9A2F5, 0x6B4FD8)
        case .teal: (0x5CC4B0, 0x0F7C6C)
        case .gold: (0xE3D36B, 0x8A7400)
        case .sky: (0x8CCBE6, 0x1B6F94)
        case .pink: (0xF0A6C8, 0xB0367A)
        case .slate: (0xA9B4CC, 0x4A5878)
        case .moss: (0xA9CF7A, 0x4C7A1E)
        case .clay: (0xD9B38C, 0x8A5A2B)
        }
    }
}

private extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
