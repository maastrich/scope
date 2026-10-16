import AppKit
import SwiftUI
import ScopeCore
import ScopeTasks
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
    @State private var defaultModel = ""
    /// Why the last image was refused, said under the wells.
    @State private var imageProblem: String?
    /// What the graph says of each repository, for the list under the Graph row.
    @State private var summaries: [RepoContextSummary]?
    private enum Field { case name, icon, context, model }
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
                SheetRow("Model") {
                    TextField("Model", text: $defaultModel, prompt: Text("driver's default"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($focus, equals: .model)
                        .scopeFieldBox(focused: focus == .model)
                        .usageID("scope-model", label: "Default model of the scope")
                        .help("What threads of this scope run on when nothing names a model: ahead of the driver's default in Settings ▸ Drivers. Only drivers that take a model use it.")
                }
            }
            tile
            contextGroup
            repositories
            disk
        } notice: {
            EmptyView()
        } actions: {
            Button("Remove Scope…") {
                Task { await ScopeActions.remove(scope, model: model) }
            }
            .buttonStyle(.scopeDanger)
            .usageID("remove-scope", label: "Remove Scope")
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.scopePrimary)
                .keyboardShortcut(.defaultAction)
                .usageID("done", label: "Done")
        }
        .frame(width: 520)
        .frame(minHeight: 300, maxHeight: 760)
        .onAppear {
            name = scope.name
            icon = scope.declaration.icon ?? ""
            context = scope.declaration.context ?? ""
            defaultModel = scope.declaration.model ?? ""
        }
        .onDisappear(perform: save)
        .task(id: model.graph.isGenerating) {
            summaries = await model.graphSummaries(for: scope)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != scope.name { model.renameScope(scope.id, name: trimmed) }
        model.setScopeContext(scope.id, context)
        model.setScopeModel(scope.id, defaultModel)
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
                            .usageID("graph-analyze", label: "Analyze")
                        Button("Analyze with AI") { Task { await model.analyzeGraph(scope: scope, withAI: true) } }
                            .buttonStyle(.scopeSecondary)
                            .usageID("graph-analyze-ai", label: "Analyze with AI")
                    }
                    Button("Open") {
                        model.selectScope(scope.id)
                        // Shown once this sheet is gone (`RootView`): a sheet asked for while another closes is dropped.
                        model.graphFollowsScopeSettings = true
                        dismiss()
                    }
                    .buttonStyle(.scopeSecondary)
                    .usageID("graph-open", label: "Open the graph")
                }
                .disabled(scope.repos.isEmpty)
            }
            // Each repository in one sentence, as agents read it in a task's context file.
            ForEach(described, id: \.path) { summary in
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.path == "." ? scope.name : summary.path)
                        .font(.scopeValue)
                        .foregroundStyle(Ink.primary)
                    Text(summary.purpose ?? "")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Disk

    /// What the scope's open tasks take on disk, from the measurements `AppModel+DiskUsage` keeps: the total and the
    /// three heaviest, so a `node_modules` per worktree is a number rather than a surprise.
    @ViewBuilder private var disk: some View {
        let usage = model.diskUsage(in: scope.id)
        let open = model.tasks(in: scope.id).count
        SheetGroup(caption: "The sandboxes of the open tasks, measured every ten minutes and after each setup. "
            + "Archiving a task frees its sandboxes; `scope gc --dry-run` prints the same figures.") {
            SectionLabel(text: "Disk")
            SheetRow("Sandboxes") {
                HStack(spacing: 8) {
                    if open == 0 {
                        Text("no open task")
                            .foregroundStyle(Ink.tertiary)
                    } else if usage.measured == 0 {
                        Text("measuring…")
                            .foregroundStyle(Ink.tertiary)
                    } else {
                        Text(SandboxSize.text(usage.total))
                            .font(.scopeValue)
                        Text("across \(usage.measured) \(usage.measured == 1 ? "task" : "tasks")"
                             + (usage.measured < open ? ", \(open - usage.measured) not measured yet" : ""))
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Measure Now") { Task { await model.refreshDiskUsage() } }
                        .buttonStyle(.scopeSecondary)
                        .disabled(open == 0)
                        .usageID("disk-measure", label: "Measure the sandboxes now")
                }
            }
            ForEach(usage.largest, id: \.task.id) { entry in
                HStack(spacing: 8) {
                    Text(entry.task.name)
                        .font(.scopeValue)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(SandboxSize.text(entry.bytes))
                        .font(.scopeValue)
                        .foregroundStyle(Ink.secondary)
                }
            }
        }
    }

    private var depth: Binding<Int> {
        Binding(get: { scope.declaration.discoveryDepth }, set: { model.setDiscoveryDepth($0, for: scope.id) })
    }

    private var graphStatus: String {
        let count = scope.repos.count
        guard count > 0 else { return "no repository" }
        guard summaries != nil else { return "\(count) \(count == 1 ? "repository" : "repositories")" }
        return "\(described.count) of \(count) described"
    }

    private var described: [RepoContextSummary] {
        (summaries ?? []).filter { $0.purpose != nil }.sorted { $0.path < $1.path }
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
