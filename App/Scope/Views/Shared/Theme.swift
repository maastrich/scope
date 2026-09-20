import SwiftUI
import ScopeGit

// The app's colour and type tokens. Every value lives in `Assets.xcassets`, which is what gives each one a
// light and a dark variant for free; this file only names the roles and is the single place a view reaches
// for one.
//
// Two tiers. `Surface` / `Fill` / `Ink` are the *surface* tier, and they are what the app was missing: before
// them, roughly twenty-five views hand-wrote `Color.primary.opacity(0.06)` against a ground they could not
// know, and the sidebar was translucent because nothing said what it should be painted with instead.
// `ThreadStateStyle` and `PullRequestStyle` are the *semantic* tier — they already existed and are unchanged
// beyond moving here.
//
// Nothing in the app is translucent any more except `PaletteDim`, which is a modal scrim rather than a
// material: it is meant to dim what is behind it, not to sample it.

/// The opaque grounds, in the order they stack. In light `surface` sits one step *below* `ground` — macOS
/// puts grey chrome around near-white content — and `panel` one step above it, so a band never comes out
/// darker than the list it heads. In dark the two are the same colour, which is what macOS does too.
enum Surface {
    /// Terminal, content panes, list wells, empty states.
    static let ground = Color("Ground")
    /// Chrome: the sidebar, the window toolbar, the sidebar footer.
    static let surface = Color("Surface")
    /// Panels inside the content well: the inspector header, the summary bands, the delta and review bars.
    static let panel = Color("SurfacePanel")
    /// Anything that floats: the command palette, popovers, the thread banner, the exit toasts.
    static let elevated = Color("SurfaceElevated")
    /// Every 1px hairline. Deliberately below 3:1 — a divider is decoration under WCAG 1.4.11, the row it
    /// separates is not.
    static let stroke = Color("Stroke")
    /// Text fields: the sidebar filter, the search fields.
    static let field = Color("Field")
}

/// Opaque fills for the states a control answers with. These replace `Color.primary.opacity(…)`, which
/// composites against whatever happens to be behind it and so drifted from view to view.
enum Fill {
    /// Chips, the state pill, count badges, a segmented control at rest.
    static let quiet = Color("FillQuiet")
    /// Row hover, icon-button hover.
    static let hover = Color("FillHover")
    /// An icon button while it is pressed.
    static let pressed = Color("FillPressed")
    /// The selected row of a list, while its window is key.
    static let selected = Color.accentColor
    /// The selected row while the window is *not* key. Its contrast against the surface is 1.39:1 and cannot
    /// reach 3:1 without reading as active; the row is identified by its full-contrast label and by the
    /// `isSelected` trait, exactly as it is in Finder.
    static let selectedInactive = Color("SelectionInactive")
    /// The selected row of a secondary list — delta files, palette results, base search. Opaque, where this
    /// used to be `Color.accentColor.opacity(0.12)`.
    static let selectedTint = Color("SelectionTint")
}

/// Text colours. `.secondary` and `.tertiary` are alpha over an unknown ground: on the opaque light surface
/// `.tertiary` renders at 4.26:1 and fails AA, which is why these are assets and not SwiftUI hierarchies.
enum Ink {
    static let primary = Color("TextPrimary")
    static let secondary = Color("TextSecondary")
    static let tertiary = Color("TextTertiary")
    /// Every glyph, label, caption and count on a selected row. No secondary tier survives on the accent
    /// fill: the darkest white that still reads as secondary is 3.99:1 against it.
    static let onAccent = Color("OnAccent")
}

/// Colours of the thread state legend: catalogue colours with light/dark variants, every one at least 3:1 on
/// its ground (WCAG 1.4.11). `done` is pinned to blue rather than the accent so it keeps its meaning — the
/// accent is now Electric, and a blue *done* beside a blue *selection* would say the same thing twice.
///
/// Five light values are a shade darker than they were: the sidebar used to be vibrancy-composited, hence
/// lighter than the opaque surface that replaced it, and `running`, `idle` and the `exited` ring fell under
/// 3:1 on the real colour.
enum ThreadStateStyle {
    static let idle = Color("StateIdle")
    static let running = Color("StateRunning")
    static let waiting = Color("StateWaiting")
    static let done = Color("StateDone")
    static let failed = Color("ChecksFailing")
    /// Reads on both the sidebar and the dark terminal.
    static let exitedRing = Color("ExitedRing")
}

/// Colours and glyphs of the PR chips: semantic assets (`ChecksPassing` #1f7a3a, `ChecksFailing` #b3261e,
/// `ChecksPending` #a84c00 in light, lifted in dark) so they keep AA contrast on both appearances.
enum PullRequestStyle {
    static let passing = Color("ChecksPassing")
    static let failing = Color("ChecksFailing")
    static let pending = Color("ChecksPending")
    static let neutral = Ink.tertiary

    static func color(_ checks: PullRequest.Checks) -> Color {
        switch checks {
        case .passing: passing
        case .failing: failing
        case .pending: pending
        case .none: neutral
        }
    }

    static func glyph(_ checks: PullRequest.Checks) -> String {
        switch checks {
        case .passing: "✓"
        case .failing: "✗"
        case .pending: "●"
        case .none: "–"
        }
    }

    static func review(_ decision: PullRequest.ReviewDecision) -> (text: String, color: Color)? {
        switch decision {
        case .approved: ("Approved", passing)
        case .changesRequested: ("Changes requested", failing)
        case .reviewRequired: ("Review needed", Ink.secondary)
        case .none: nil
        }
    }
}

/// The type scale. The views reached for seventeen distinct sizes; these six roles cover every one of them,
/// and a size that is not one of them is a bug rather than a decision.
extension Font {
    /// A name at the head of a panel: the task in the summary band, a banner title, a sheet heading.
    static let scopeTitle = Font.system(size: 13, weight: .semibold)
    /// Ordinary body text: sidebar row titles, palette results, settings labels.
    static let scopeBody = Font.system(size: 13)
    /// Dense list rows: thread and task titles, delta file paths.
    static let scopeRow = Font.system(size: 11.5)
    /// Captions, paths, prompts, helper text.
    static let scopeCaption = Font.system(size: 11)
    /// Group headers, uppercase labels, badge digits.
    static let scopeMicro = Font.system(size: 9.5, weight: .semibold)
    /// Anything that *is* a value: `+N −M`, branch names, hashes.
    static let scopeValue = Font.system(size: 11, design: .monospaced)
}

/// Corner radii. Three, where the views used five.
enum Radius {
    /// Chips, badges, status letters.
    static let sm: CGFloat = 4
    /// Rows, buttons, fields, the ends of a segmented control.
    static let md: CGFloat = 5
    /// Anything elevated: the palette, the banner, the toasts.
    static let lg: CGFloat = 10
}

/// True while the view is being drawn on the accent selection fill of a key window.
///
/// A `List` inverts the foreground of the `Text` it owns, but it knows nothing about a caption that asked for
/// `.secondary`, a `+N −M` that asked for green, or a state dot that paints itself: those keep their own
/// colour and become unreadable on the fill — green on Electric is 1.9:1. The rows set this, and everything
/// that carries its own colour reads it.
private struct OnAccentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isOnAccent: Bool {
        get { self[OnAccentKey.self] }
        set { self[OnAccentKey.self] = newValue }
    }
}

extension View {
    /// Marks a row's subtree as sitting on the accent fill: `selected` *and* the window key, since an inactive
    /// window greys its selection and the row goes back to its ordinary colours.
    func onAccent(_ selected: Bool, _ active: ControlActiveState) -> some View {
        environment(\.isOnAccent, selected && active == .key)
    }
}
