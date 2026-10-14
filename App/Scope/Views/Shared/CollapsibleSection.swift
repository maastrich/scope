import AppKit
import SwiftUI
import ScopeCore

/// One section of the inspector column, VSCode-style: a 22 pt header with a chevron and a short title, then the body
/// when open. Closed, the header carries the section's summary, so leaving it closed loses nothing essential.
///
/// What sits in the header is split by how often it is needed. `accessories` are state the eye needs at rest (the
/// Delta mode, the repository picker, Pull when the base is behind) and stay visible; `actions` are things you reach
/// for (refresh, open in editor, reveal) and appear over the summary while the pointer is on the header — a row of
/// buttons that always shows costs a line of height for a click made once in a while.
///
/// A list (`InspectorSection.fills`) takes exactly the height the column gives it; a block scrolls inside its height
/// and reports the height its content asks for through `onNatural`, which is how the column sizes it.
struct CollapsibleSection<Summary: View, Accessories: View, Actions: View, Content: View>: View {
    @Environment(AppModel.self) private var model
    let section: InspectorSection
    /// Body height from the column's layout; `nil` while closed.
    let bodyHeight: Double?
    /// What the header says when the section has nothing to show (no task, no repository).
    var unavailable = "no task"
    var help = ""
    var onNatural: (Double) -> Void = { _ in }
    /// Set when an open list sits above this one: the header's top edge is then the sash between the two.
    var sash: SectionSash?
    @ViewBuilder var summary: Summary
    @ViewBuilder var accessories: Accessories
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        let available = model.isSectionAvailable(section)
        let open = available && model.isSectionOpen(section)
        VStack(spacing: 0) {
            Divider()
            header(open: open, available: available)
            if open, let bodyHeight {
                Group {
                    if section.fills {
                        content
                    } else {
                        ScrollView(.vertical) {
                            content
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { onNatural($0) }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                }
                .frame(height: bodyHeight, alignment: .top)
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
    }

    private func header(open: Bool, available: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(section.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(open ? Ink.primary : Ink.secondary)
                .lineLimit(1)
                .fixedSize()
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if !available {
                        Text(unavailable)
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                    } else if !open {
                        summary
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .clipped()
                if available {
                    // Always in the hierarchy (Tab and VoiceOver reach them), drawn over the summary on hover.
                    HStack(spacing: 2) { actions }
                        .buttonStyle(.iconTight)
                        .foregroundStyle(Ink.secondary)
                        .font(.system(size: 11))
                        .padding(.leading, 8)
                        .background(Surface.panel)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                }
            }
            if available {
                accessories
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: InspectorSectionLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Surface.panel)
        .opacity(available ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if available { model.toggleSection(section) } }
        .onHover { hovering = $0 }
        .overlay(alignment: .top) {
            if let sash { SashHandle(sash: sash) }
        }
        .help(available ? help : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
        .accessibilityValue(open ? "expanded" : "collapsed")
        .accessibilityAction(named: open ? "Collapse" : "Expand") { model.toggleSection(section) }
    }
}

/// A drag that moves height between two parts of the column; the translation is measured from the drag's start.
struct SectionSash {
    var began: () -> Void
    var moved: (Double) -> Void
    var ended: () -> Void
}

/// The invisible grip on a boundary: a few points tall, the resize pointer over it.
struct SashHandle: View {
    let sash: SectionSash
    @State private var dragging = false

    var body: some View {
        Color.clear
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .offset(y: -3)
            .cursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            sash.began()
                        }
                        sash.moved(Double(value.translation.height))
                    }
                    .onEnded { _ in
                        dragging = false
                        sash.ended()
                    }
            )
            .accessibilityHidden(true)
    }
}

extension CollapsibleSection where Accessories == EmptyView {
    init(section: InspectorSection, bodyHeight: Double?, unavailable: String = "no task", help: String = "",
         onNatural: @escaping (Double) -> Void = { _ in }, sash: SectionSash? = nil,
         @ViewBuilder summary: () -> Summary, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.init(section: section, bodyHeight: bodyHeight, unavailable: unavailable, help: help, onNatural: onNatural,
                  sash: sash, summary: summary, accessories: { EmptyView() }, actions: actions, content: content)
    }
}

/// A choice in a section header (the Delta mode, the Base repository): the value and a chevron on a quiet 18 pt
/// chip, so it reads as state in a 22 pt header rather than as a toolbar control.
struct HeaderPicker<Value: Hashable, Content: View>: View {
    var label: String
    @Binding var selection: Value
    var title: String
    @ViewBuilder var content: Content

    init(_ label: String, selection: Binding<Value>, title: String, @ViewBuilder content: () -> Content) {
        self.label = label
        _selection = selection
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScopeMenu {
            Picker(label, selection: $selection) { content }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: { hovering in
            HStack(spacing: 3) {
                Text(title)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(hovering ? Fill.hover : Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }
}

/// A labelled button in a section header (Pull): same 18 pt chip as `HeaderPicker`.
struct HeaderChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.scopeCaption)
                .foregroundStyle(Ink.primary)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(configuration.isPressed ? Fill.pressed : (hovering ? Fill.hover : Fill.quiet),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == HeaderChipButtonStyle {
    static var headerChip: HeaderChipButtonStyle { HeaderChipButtonStyle() }
}
