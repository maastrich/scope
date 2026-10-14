import AppKit
import SwiftUI
import ScopeCore
import UniformTypeIdentifiers

/// Everything the owner decides about one scope, in one place: its name, what its tile shows in each
/// appearance, what agents should know about it, how deep its repositories are looked for, and its graph.
/// Opened from the scope's menu or a right-click on its tile.
///
/// The tile and the depth apply as they are changed — the sidebar behind the sheet is the preview. The name and
/// the context are saved when the sheet closes: half a name is not a name, and the context rewrites files.
struct ScopeSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let scope: ScopeState

    @State private var name = ""
    @State private var icon = ""
    @State private var context = ""
    /// Why the last image was refused, said under the wells.
    @State private var imageProblem: String?
    @State private var described: Int?
    private enum Field { case name, icon, context }
    @FocusState private var focus: Field?

    var body: some View {
        SheetChrome(title: "Settings of \(scope.name)") {
            SheetGroup {
                SheetRow("Name") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .name)
                        .scopeFieldBox(focused: focus == .name)
                }
                SheetRow("Folder") {
                    HStack(spacing: 8) {
                        Text(scope.url.path)
                            .font(.scopeValue)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        Button("Reveal") { Reveal.inFinder(scope.url) }
                            .buttonStyle(.scopeLink)
                    }
                }
            }
            tile
            contextGroup
            repositories
        } notice: {
            EmptyView()
        } actions: {
            Button("Remove Scope…") {
                Task { await ScopeActions.remove(scope, model: model) }
            }
            .buttonStyle(.scopeDanger)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.scopePrimary)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 520)
        .frame(minHeight: 300, maxHeight: 760)
        .onAppear {
            name = scope.name
            icon = scope.declaration.icon ?? ""
            context = scope.declaration.context ?? ""
        }
        .onDisappear(perform: save)
        .task(id: model.graph.isGenerating) {
            described = await model.graphSummaries(for: scope).count { $0.purpose != nil }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != scope.name { model.renameScope(scope.id, name: trimmed) }
        model.setScopeContext(scope.id, context)
    }

    // MARK: Tile

    @ViewBuilder private var tile: some View {
        SheetGroup(caption: "An image takes the place of the letter. It is copied, reduced and always kept inside the square; "
            + "drop one on a well, or on the scope's tile in the sidebar. Without a dark image, the one image is shown in both appearances.") {
            SectionLabel(text: "Tile")
            HStack(alignment: .top, spacing: 12) {
                ScopeImageWell(scope: scope, slot: .standard, problem: $imageProblem)
                ScopeImageWell(scope: scope, slot: .dark, problem: $imageProblem)
            }
            if let imageProblem {
                Label(imageProblem, systemImage: "exclamationmark.triangle")
                    .font(.scopeCaption)
                    .foregroundStyle(PullRequestStyle.failing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SheetRow("Letter") {
                TextField(scope.declaration.monogram, text: $icon)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .icon)
                    .scopeFieldBox(focused: focus == .icon)
                    .frame(width: 64)
                    .onChange(of: icon) { _, text in
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard value != (scope.declaration.icon ?? "") else { return }
                        model.updateScopeIdentity(scope.id) { $0.icon = value.isEmpty ? nil : value }
                    }
                    .help("An emoji, or a letter or two, in place of the first letter of the name")
            }
            SheetRow("Colour") {
                HStack(spacing: 7) {
                    Button("Automatic") { model.updateScopeIdentity(scope.id) { $0.tint = nil } }
                        .buttonStyle(.scopeSecondary)
                        .opacity(scope.declaration.tint == nil ? 1 : 0.6)
                    ForEach(ScopeTint.allCases, id: \.self) { tint in
                        Button {
                            model.updateScopeIdentity(scope.id) { $0.tint = tint }
                        } label: {
                            Circle()
                                .fill(ScopeTintStyle.fill(tint))
                                .frame(width: 16, height: 16)
                                .padding(3)
                                .overlay {
                                    if scope.declaration.resolvedTint == tint {
                                        Circle().strokeBorder(Ink.primary, lineWidth: 1.5)
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(tint.title)
                        .accessibilityLabel(tint.title)
                    }
                }
            }
        }
    }

    // MARK: Context

    @ViewBuilder private var contextGroup: some View {
        SheetGroup(caption: "Added to the context file of every task of this scope, under “About \(scope.name)”. "
            + "Say what no repository says by itself: what the scope is, how its repositories fit together, the rules that hold across them.") {
            SectionLabel(text: "Context for agents")
            TextEditor(text: $context)
                .font(.scopeBody)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 144)
                .focused($focus, equals: .context)
                .scopeTextBox(focused: focus == .context, inset: 2)
        }
    }

    // MARK: Repositories and graph

    @ViewBuilder private var repositories: some View {
        SheetGroup(caption: "The graph is what Scope knows about each repository — what it is for, its stack, how to set it up and test it. "
            + "It feeds the context file too.") {
            SectionLabel(text: "Repositories")
            SheetRow("Look in") {
                ScopePicker("Discovery depth", selection: depth, title: depthLabel(scope.declaration.discoveryDepth)) {
                    ForEach(Array(ScopeDeclaration.depthRange), id: \.self) { Text(depthLabel($0)).tag($0) }
                }
            }
            SheetRow("Graph") {
                HStack(spacing: 8) {
                    Text(graphStatus)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if model.graph.isGenerating {
                        ScopeSpinner(size: 10)
                    } else {
                        Button("Analyze") { Task { await model.analyzeGraph(scope: scope, withAI: false) } }
                            .buttonStyle(.scopeSecondary)
                        Button("Analyze with AI") { Task { await model.analyzeGraph(scope: scope, withAI: true) } }
                            .buttonStyle(.scopeSecondary)
                    }
                    Button("Open") {
                        model.selectScope(scope.id)
                        dismiss()
                        // After the dismissal: a sheet asked for while another closes is dropped.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.presentGraph() }
                    }
                    .buttonStyle(.scopeSecondary)
                }
                .disabled(scope.repos.isEmpty)
            }
        }
    }

    private var depth: Binding<Int> {
        Binding(get: { scope.declaration.discoveryDepth }, set: { model.setDiscoveryDepth($0, for: scope.id) })
    }

    private var graphStatus: String {
        let count = scope.repos.count
        guard count > 0 else { return "no repository" }
        guard let described else { return "\(count) \(count == 1 ? "repository" : "repositories")" }
        return "\(described) of \(count) described"
    }

    private func depthLabel(_ depth: Int) -> String {
        switch depth {
        case 0: "The folder itself"
        case 1: "Its direct children"
        default: "\(depth) levels down"
        }
    }
}

/// One of the two images of a tile: the tile as that appearance shows it, on that appearance's ground, and the
/// three ways to put an image there — choose a file, paste, drop.
private struct ScopeImageWell: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let slot: ScopeLogoSlot
    @Binding var problem: String?
    @State private var targeted = false

    private var dark: Bool { slot == .dark }
    private var hasImage: Bool { scope.declaration[keyPath: slot.keyPath] != nil }

    var body: some View {
        HStack(spacing: 10) {
            ScopeTileFace(declaration: scope.declaration, logo: model.scopeLogo(scope, dark: dark), size: 32)
                .frame(width: 56, height: 56)
                // The sidebar's ground in that appearance, whatever the window is in.
                .background(dark ? ScopeTintStyle.darkPlate : Color(nsColor: NSColor(srgbRed: 1, green: 1, blue: 0.976, alpha: 1)),
                            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Surface.stroke, lineWidth: 1) }
                .environment(\.colorScheme, dark ? .dark : .light)
            VStack(alignment: .leading, spacing: 5) {
                Text(dark ? "Dark appearance" : "Image")
                    .font(.scopeBody)
                    .foregroundStyle(Ink.primary)
                HStack(spacing: 6) {
                    Button("Choose…", action: choose)
                        .buttonStyle(.scopeSecondary)
                    Button("Paste", action: paste)
                        .buttonStyle(.scopeSecondary)
                }
                Button(dark && !hasImage ? "Same as the image" : "Remove") {
                    problem = nil
                    model.removeScopeLogo(scope.id, slot)
                }
                .buttonStyle(.scopeLink)
                .disabled(!hasImage)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(targeted ? 1 : 0)
        }
        .onDrop(of: ScopeImageDrop.types, isTargeted: $targeted) { providers in
            ScopeImageDrop.load(providers) { set($0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dark ? "Image in the dark appearance" : "Image")
    }

    private func set(_ source: ScopeLogoSource) {
        do {
            try model.setScopeLogo(scope.id, slot, from: source)
            problem = nil
        } catch {
            problem = ScopeActions.imageRefusal(error)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .svg, .pdf]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Image"
        panel.message = "Choose an image for the tile of \(scope.name). Scope keeps its own reduced copy."
        if panel.runModal() == .OK, let url = panel.url { set(.file(url)) }
    }

    private func paste() {
        guard let source = ScopeLogoSource.pasteboard() else {
            problem = "The clipboard holds no image."
            return
        }
        set(source)
    }
}
