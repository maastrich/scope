import SwiftUI
import ScopeGraph

/// One repository card: name, `owner/repo`, branch and age; two lines of description; one row of tags; a folded
/// *Details* section with the commands and the relations. The actions (editor, base, Finder, edit) appear on hover
/// or keyboard focus, and are the card's context menu and VoiceOver actions too — they used to be a bar repeated
/// under every card. Switches to `RepoCardEditor` while the card is being edited.
struct RepoCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: ScopeState
    let entry: GraphCardEntry
    /// The Graph view's side panel: details always open, no hover bar (the panel is the selection already).
    var isPanel = false

    @State private var hovering = false
    @FocusState private var focused: Bool

    private var card: RepoCard { entry.card }
    private var actions: RepoActions { RepoActions(model: model, scope: scope, entry: entry) }
    private var showsDetails: Bool { isPanel || model.graph.expanded.contains(entry.key) }

    var body: some View {
        Group {
            if model.graph.editingKey == entry.key {
                RepoCardEditor(entry: entry)
            } else {
                content
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Surface.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isMarked ? Color.accentColor : Surface.stroke, lineWidth: isMarked ? 2 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if !isPanel, hovering || focused, model.graph.editingKey != entry.key {
                hoverBar.padding(6).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering || focused)
        .onHover { hovering = $0 }
        .focusable(!isPanel && model.graph.editingKey != entry.key)
        .focused($focused)
        .focusEffectDisabled()
        // The keyboard path to what the hover bar offers: Tab to a card, ⌘E opens it, Space or ↩ unfolds it; the
        // rest is in the context menu and the VoiceOver actions.
        .onKeyPress(.space) { toggleDetails(); return .handled }
        .onKeyPress(.return) { toggleDetails(); return .handled }
        .onKeyPress(characters: ["e"], phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            actions.openInEditor()
            return .handled
        }
        .contextMenu { actions.menuItems() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
        .accessibilityAction(named: showsDetails ? "Hide details" : "Show details") { toggleDetails() }
        .accessibilityAction(named: "Open in Editor") { actions.openInEditor() }
        .accessibilityAction(named: "Show in Base") { actions.showBase() }
        .accessibilityAction(named: "Reveal in Finder") { actions.reveal() }
        .accessibilityAction(named: "Show in Graph") { actions.showInGraph() }
        .accessibilityAction(named: "Edit Card") { actions.edit() }
    }

    private var isMarked: Bool { focused || model.graph.highlightedKey == entry.key }

    private var accessibilityName: String {
        [card.name, entry.subtitle, entry.domain.title].compactMap { $0 }.joined(separator: ", ")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            description
            if !entry.tags.isEmpty { TagRow(tags: entry.tags) }
            detailsToggle
            if showsDetails { details }
        }
    }

    /// The name and `owner/repo` are never cut: the name wraps onto a second line, and `owner/repo` has a line of its
    /// own under the row it used to share with the branch and the date (which squeezed it to `mobsucces…ccess-front`).
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            nameRow
            if let subtitle = entry.subtitle {
                Text(subtitle)
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !isPanel {
                // The line stays, empty, so a card without a remote lines up with its neighbours.
                Text(" ").font(.scopeCaption).accessibilityHidden(true)
            }
        }
    }

    private var nameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(card.name)
                .font(.scopeTitle)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if card.edited {
                    Text("edited")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color("WarningText"))
                        .help("Edited by hand: Analyze keeps this card")
                }
                if let branch = card.defaultBranch {
                    Text(branch).font(.system(size: 10.5, design: .monospaced))
                }
                if card.defaultBranch != nil, card.lastActivity != nil { Text("·") }
                if let date = card.lastActivity {
                    Text(date.formatted(.relative(presentation: .named)))
                        .help("Last commit \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.scopeCaption)
            .foregroundStyle(Ink.tertiary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// Always two lines tall, so the cards of a row line up whatever their text.
    private var description: some View {
        Group {
            if let description = entry.description {
                Text(description.text)
                    .foregroundStyle(Ink.secondary)
                    .help(description.text)
            } else {
                Text("No description")
                    .foregroundStyle(Ink.tertiary)
                    .italic()
            }
        }
        .font(.system(size: 12))
        .lineSpacing(2)
        .lineLimit(isPanel ? 12 : 2, reservesSpace: !isPanel)
        .fixedSize(horizontal: false, vertical: isPanel)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailsToggle: some View {
        if !isPanel {
            Button(action: toggleDetails) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    Text("Details")
                }
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsDetails ? "Hide details" : "Show details")
        }
    }

    private func toggleDetails() {
        if model.graph.expanded.remove(entry.key) == nil { model.graph.expanded.insert(entry.key) }
    }

    private var details: some View {
        let relations = model.graph.relations(of: entry.key)
        return VStack(alignment: .leading, spacing: 6) {
            // The whole description, when two lines of a card cannot have held it (the panel shows it whole above).
            if let description = entry.description, !isPanel, description.text.count > 130 {
                Text(description.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let description = entry.description {
                row("About") { Text(sourceCaption(description.source)).font(.scopeCaption).foregroundStyle(Ink.tertiary) }
            }
            if !card.entrypoints.isEmpty { row("Entry") { mono(card.entrypoints.joined(separator: "\n")) } }
            if let setup = card.setup, !setup.isEmpty { row("Setup") { mono(setup) } }
            if let test = card.test, !test.isEmpty { row("Test") { mono(test) } }
            if let teardown = card.teardown, !teardown.isEmpty { row("Teardown") { mono(teardown) } }
            if !relations.out.isEmpty { row("Uses") { links(relations.out, systemImage: "arrow.right") } }
            if !relations.in.isEmpty { row("Used by") { links(relations.in, systemImage: "arrow.left") } }
            if card.entrypoints.isEmpty, card.setup == nil, card.test == nil, relations.out.isEmpty, relations.in.isEmpty {
                Text("Nothing more known. Analyze with AI fills the commands and the relations.")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
            }
            if isPanel {
                HStack(spacing: 4) {
                    Button { actions.openInEditor() } label: { Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { actions.showBase() } label: { Label("Base", systemImage: "square.stack.3d.up") }
                    Button { actions.reveal() } label: { Label("Reveal", systemImage: "folder") }
                    Spacer(minLength: 0)
                    Button { actions.showCard() } label: { Label("Card", systemImage: "rectangle.grid.2x2") }
                }
                .buttonStyle(.scopeLink)
                .font(.scopeCaption.weight(.medium))
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    private func sourceCaption(_ source: RepoDescription.Source) -> String {
        switch source {
        case .edited: "written by hand"
        case .github: "from GitHub"
        case .manifest: "from the manifest"
        case .ai: "from the AI analysis"
        case .readme: "from the README"
        }
    }

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .frame(width: 54, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The whole command, wrapped and selectable: a setup is copied more often than it is read.
    private func mono(_ text: String) -> some View {
        Text(text)
            .font(.scopeValue)
            .foregroundStyle(Ink.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func links(_ keys: [String], systemImage: String) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                Button {
                    model.graph.highlightedKey = key
                    if isPanel { model.graph.selectedKey = key }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                        Text(model.graph.card(key)?.name ?? key)
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.scopeLink)
            }
        }
    }

    /// The hover bar: three actions and a menu, over the card's corner.
    private var hoverBar: some View {
        HStack(spacing: 1) {
            if let repo = actions.repo {
                CheckoutPicker(scope: scope, repo: repo, iconOnly: true)
                Button { actions.showBase() } label: { Image(systemName: "square.stack.3d.up") }
                    .help("Show in Base")
                    .accessibilityLabel("Show in Base")
                Button { actions.reveal() } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
            }
            ScopeIconMenu(systemImage: "ellipsis", title: "More") {
                actions.menuItems()
            }
        }
        .buttonStyle(IconButtonStyle(padding: 3))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Ink.secondary)
        .padding(2)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Surface.stroke))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
    }
}
