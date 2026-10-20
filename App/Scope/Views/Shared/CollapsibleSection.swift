import AppKit
import SwiftUI
import ScopeCore

/// One card of the inspector column: a 28 pt header with a chevron, a sentence-case title and — closed — the
/// card's summary at the right, then the body when open. Leaving a card closed loses nothing essential.
///
/// A card is a bordered panel on the ground (`Surface.panel`, 1 pt `Surface.stroke`, radius 8) with
/// `InspectorSectionLayout.cardGap` of air to the next, so the column reads as a stack of answers rather than a table
/// of contents. What sits in the header is split by how often it is needed. `accessories` are state the eye needs at
/// rest (the Changes mode, the repository picker, Pull when the base is behind) and stay visible; `actions` are things
/// you reach for (refresh, open in editor, reveal) and appear over the summary while the pointer is on the header — a
/// row of buttons that always shows costs a line of height for a click made once in a while.
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
    /// The menu command that opens and focuses the section (`command.delta`), for the ⌘-held hint on its header.
    var command: String? = nil
    var onNatural: (Double) -> Void = { _ in }
    /// Set when an open list sits above this one: the gap over the card is then the sash between the two.
    var sash: SectionSash?
    @ViewBuilder var summary: Summary
    @ViewBuilder var accessories: Accessories
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content
    @State private var hovering = false

    static var cornerRadius: CGFloat { 8 }

    var body: some View {
        let available = model.isSectionAvailable(section)
        let open = available && model.isSectionOpen(section)
        VStack(spacing: 0) {
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
                // On screen while open and while the inspector shows: what the time spent in a section means.
                .onAppear { Usage.opened(usageArea, label: section.title) }
                .onDisappear { Usage.closed(usageArea) }
            }
        }
        .background(Surface.panel)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Surface.stroke, lineWidth: 1)
        }
        .overlay(alignment: .top) {
            // Centred on the gap above the card, so the grip reaches into neither header.
            if let sash { SashHandle(sash: sash).offset(y: -InspectorSectionLayout.cardGap / 2) }
        }
        .opacity(available ? 1 : 0.6)
        .usageArea(usageArea)
    }

    private var usageArea: String { UsageID.join("inspector", UsageID.slug(section.title)) }

    private func header(open: Bool, available: Bool) -> some View {
        HStack(spacing: 6) {
            toggleArea(open: open, available: available)
            if available {
                accessories
            }
            Spacer(minLength: 4)
            trailing(open: open, available: available)
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .frame(height: InspectorSectionLayout.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Surface.panel)
        .onHover { hovering = $0 }
        .help(available ? help : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.title)
        .accessibilityValue(open ? "expanded" : "collapsed")
        .accessibilityAction(named: open ? "Collapse" : "Expand") { model.toggleSection(section) }
    }

    /// Chevron and title: the part of the header a click folds. The accessories sit outside it, so opening the mode
    /// or repository menu does not fold the section under the pointer.
    private func toggleArea(open: Bool, available: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 10)
                .accessibilityHidden(true)
            Text(section.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .fixedSize()
                // ⌘D / ⇧⌘B after the title, while ⌘ is held.
                .keyHints(.custom(.trailing, .zero)) { command.flatMap { CommandKeyHints.shared.keys(for: $0) }.map { [$0] } ?? [] }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard available else { return }
            Usage.click(UsageID.join(usageArea, "header"), label: "\(section.title) header")
            model.toggleSection(section)
        }
    }

    /// The right of the header: the summary while closed (or the reason the card is empty), the actions drawn over
    /// it while the pointer is on the header. A click here folds the card too, unless it lands on an action.
    private func trailing(open: Bool, available: Bool) -> some View {
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
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                guard available else { return }
                model.toggleSection(section)
            }
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
        .layoutPriority(-1)
    }
}

/// A drag that moves height between two parts of the column; the translation is measured from the drag's start. A
/// double-click (`reset`) gives the two lists the same height again.
struct SectionSash {
    var began: () -> Void
    var moved: (Double) -> Void
    var ended: () -> Void
    var reset: () -> Void
}

/// The grip over a card under another open list: `Sash` across the width, centred on the gap between the two cards.
struct SashHandle: View {
    let sash: SectionSash

    var body: some View {
        Sash(axis: .horizontal, drawsLine: false, began: sash.began, moved: sash.moved, ended: sash.ended, reset: sash.reset)
            .frame(height: 0)
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
