import ScopeCore
import SwiftUI

// The settings window's own chrome, in place of `Form` / `.formStyle(.grouped)` / `Section` /
// `LabeledContent`.
//
// Those four are what made this window read as System Settings — not the controls inside them. A grouped form
// draws inset rounded group boxes, a system label column and system row separators, all sized by the OS; swap
// the toggles inside it and you get our switches sitting in Apple's boxes. So the container goes first, and
// the controls follow it.
//
// The register is the one the rest of the app now uses: one ground, a section label, rows separated by a
// hairline, the control trailing. No box, because a group that is already introduced by its own label does
// not also need an outline.

/// Replaces `Form { … }.formStyle(.grouped)`.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Surface.ground)
    }
}

/// Replaces `Section("Title") { … }`. Rows inside are separated by a hairline, never boxed.
struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .usageArea(UsageID.join("settings", UsageID.slug(title)))
    }
}

/// Replaces `LabeledContent`: the label in secondary ink, the control trailing, a hairline under the row.
///
/// The row is 28 pt like every other row in the app and grows when its control needs the height — a path that
/// wraps, a caption under a toggle — rather than clipping, which is what a fixed height would do to the
/// longest string in a localisation.
struct SettingsRow<Control: View>: View {
    var label: String
    var caption: String?
    @ViewBuilder var control: Control

    init(_ label: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.scopeBody)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                control
                    .font(.scopeBody)
            }
            .frame(minHeight: 28)
            if let caption {
                Text(caption)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Surface.stroke).frame(height: 1) }
    }
}

extension SettingsRow where Control == Text {
    /// `LabeledContent("Label", value: "…")`.
    init(_ label: String, value: String, caption: String? = nil) {
        self.init(label, caption: caption) { Text(value).foregroundStyle(Ink.primary) }
    }
}

/// A full-width row whose whole content is one control — a toggle with its label, a paragraph of help text.
struct SettingsBlock<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(Surface.stroke).frame(height: 1) }
    }
}

/// The settings window itself: our tab strip over our pages, in place of `TabView` + `.tabItem`.
///
/// A `TabView` on macOS draws the system's own tab bar — the pill row at the top of every System Settings
/// pane. `TabStrip` is the one the inspector already uses, so the two windows agree.
struct SettingsChrome<Content: View>: View {
    @Binding var selection: SettingsTab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TabStrip(selection: $selection,
                         items: SettingsTab.allCases.map { ($0, $0.title) })
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(Surface.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Surface.stroke).frame(height: 1) }
            content
        }
        .background(Surface.ground)
    }
}

enum SettingsTab: String, CaseIterable, Hashable {
    case general, shell, drivers, automation, assist

    var title: String {
        switch self {
        case .general: "General"
        case .shell: "Shell Environment"
        case .drivers: "Drivers"
        case .automation: "Automation"
        case .assist: "Assist"
        }
    }
}
