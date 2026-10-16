import AppKit
import SwiftUI
import ScopeControl
import ScopeGit
import ScopeTasks

/// The attempts of one brief side by side (spec §4.3, best-of-N): one column per attempt — status, tokens, agent
/// time, files changed, what the last reply says about tests, the opening of the deliverable — and under them the
/// diff of one attempt against another, or against the base, drawn by the same renderer as the Delta column.
///
/// Keys: `1`…`N` put that attempt on the left, `⇧1`…`⇧N` on the right, `0` the base on the right. Read off the
/// physical key, so a layout that needs ⇧ for its digits still picks the left side with a plain press. **Keep this
/// one** in a column renames that task to the brief, moves its branch to the plain name and archives the others; a
/// file in the list can be copied into another attempt from its menu.
struct CompareAttemptsView: View {
    @Environment(AppModel.self) private var model
    let group: String

    @State private var selection = TaskAttempts.Selection.initial
    @State private var repoID: String?
    @State private var files: [DiffFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selectedFile: String?
    @State private var collapsed: Set<Int> = []
    @State private var loadCount = 0

    private var attempts: [TaskState] { model.attempts(inGroup: group) }
    private var columns: [TaskAttempts.Column] { model.attemptColumns(for: group) }
    private var open: [TaskState] { attempts.filter { !$0.isArchived } }
    private var left: TaskState? { attempts.first { $0.record.attempt?.index == selection.left } }
    private var right: TaskState? { selection.right.flatMap { index in attempts.first { $0.record.attempt?.index == index } } }
    private var repos: [TaskRepo] { left?.record.activeRepos ?? [] }
    private var repo: TaskRepo? { repos.first { $0.id == repoID } ?? repos.first }
    private var baseName: String { attempts.first?.record.attempt?.baseName ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(columns) { column in
                        attemptColumn(column)
                        Divider()
                    }
                }
            }
            .frame(height: 290)
            Divider()
            diffBar
            Divider()
            diffPane
        }
        .background(KeyCodeMonitor(handle: handleKey))
        .onAppear { if left == nil, let first = attempts.first?.record.attempt?.index { selection = .init(left: first, right: nil) } }
        .task(id: diffKey) { await loadDiff() }
        .onChange(of: attempts.map(\.changeTick).reduce(0, +)) { loadCount += 1 }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(baseName)
                .font(.scopeBody)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Text("\(attempts.count) attempts · same brief, one branch each")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
            Spacer()
            Text("1–\(attempts.count) left · ⇧1–\(attempts.count) right · 0 base")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    // MARK: Columns

    @ViewBuilder private func attemptColumn(_ column: TaskAttempts.Column) -> some View {
        let isLeft = column.index == selection.left
        let isRight = column.index == selection.right
        let task = attempts.first { $0.id.rawValue == column.id }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(column.index)")
                    .font(.scopeMicro)
                    .foregroundStyle(isLeft || isRight ? Ink.onAccent : Ink.secondary)
                    .frame(width: 18, height: 18)
                    .background(isLeft || isRight ? Fill.selected : Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                Text(column.name)
                    .font(.scopeTitle)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isLeft || isRight {
                    Text(isLeft && isRight ? "L R" : isLeft ? "L" : "R")
                        .font(.scopeMicro)
                        .foregroundStyle(Ink.secondary)
                }
            }
            Text(column.branch)
                .font(.scopeValue)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                fact("Status", column.status)
                fact("Model", [column.driver, column.model].compactMap { $0 }.isEmpty ? "—" : [column.driver, column.model].compactMap { $0 }.joined(separator: " · "))
                fact("Tokens", column.tokens.map(TokenUsageText.compact) ?? "—")
                fact("Agent time", TaskAttempts.duration(column.agentSeconds))
                fact("Files", column.filesChanged == 0 ? column.changes : "\(column.filesChanged) · \(column.changes)")
                fact("Tests", column.tests ?? "—")
            }
            .font(.scopeCaption)
            Text(column.excerpt ?? "No answer yet")
                .font(.scopeValue)
                .foregroundStyle(column.excerpt == nil ? Ink.tertiary : Ink.secondary)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
            if let task, !task.isArchived {
                HStack(spacing: 6) {
                    Button("Keep this one") { Task { await model.keepAttempt(task) } }
                        .buttonStyle(.scopePrimary)
                        .usageID("keep-attempt", label: "Keep this attempt")
                    Spacer(minLength: 0)
                    Button("Go to task") {
                        model.globalSheet = nil
                        model.selection = .task(task.id)
                    }
                    .buttonStyle(.scopeLink)
                    .usageID("go-to-attempt", label: "Go to an attempt's task")
                }
                .font(.scopeCaption)
            }
        }
        .padding(12)
        .frame(width: max(250, 1040 / CGFloat(max(1, columns.count))), alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isLeft ? Fill.selectedTint.opacity(0.35) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                selection = TaskAttempts.Selection(left: selection.left, right: column.index)
            } else {
                selection = TaskAttempts.Selection(left: column.index, right: selection.right)
            }
        }
        .help("Click: compare on the left · ⇧click: on the right")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attempt \(column.index), \(column.status)")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Ink.tertiary)
            Text(value).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    // MARK: Diff

    private var diffBar: some View {
        HStack(spacing: 10) {
            ScopePicker("Left", selection: Binding(get: { selection.left }, set: { selection = .init(left: $0, right: selection.right) }),
                        title: sideTitle(selection.left)) {
                ForEach(attempts, id: \.id) { task in
                    Text(sideTitle(task.record.attempt?.index ?? 0)).tag(task.record.attempt?.index ?? 0)
                }
            }
            Text("vs").font(.scopeCaption).foregroundStyle(Ink.tertiary)
            ScopePicker("Right", selection: Binding(get: { selection.right ?? 0 }, set: { selection = .init(left: selection.left, right: $0 == 0 ? nil : $0) }),
                        title: selection.right.map(sideTitle) ?? "base") {
                Text("base").tag(0)
                ForEach(attempts, id: \.id) { task in
                    Text(sideTitle(task.record.attempt?.index ?? 0)).tag(task.record.attempt?.index ?? 0)
                }
            }
            if repos.count > 1 {
                ScopePicker("Repository", selection: Binding(get: { repo?.id ?? "" }, set: { repoID = $0 }), title: repo?.name ?? "") {
                    ForEach(repos) { repo in Text(repo.name).tag(repo.id) }
                }
            }
            Spacer()
            if loading { ScopeSpinner(size: 10) }
            Text(summaryLine)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
        }
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private var summaryLine: String {
        let summary = DiffSummary(files)
        if summary.isEmpty { return error ?? (selection.right == nil ? "no change against the base" : "identical, as committed") }
        let counts = "\(summary.files) files · +\(summary.additions) −\(summary.deletions)"
        guard let right = selection.right else { return counts + " · attempt \(selection.left) against its base" }
        return counts + " · + is attempt \(selection.left), − attempt \(right) · commits only"
    }

    private func sideTitle(_ index: Int) -> String { "attempt \(index)" }

    @ViewBuilder private var diffPane: some View {
        if let error, files.isEmpty {
            Text(error)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            Text(selection.right == nil ? "Nothing changed against the base." : "The two branches hold the same tree.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                fileList
                    .frame(width: 240)
                Divider()
                if let file = files.first(where: { $0.path == selectedFile }) ?? files.first {
                    fileView(file)
                }
            }
        }
    }

    private var fileSelection: Binding<String?> {
        Binding(get: { selectedFile ?? files.first?.path }, set: { selectedFile = $0 })
    }

    private var fileList: some View {
        List(files, selection: fileSelection) { file in
            CompareFileRow(file: file)
                .tag(file.path)
                .contextMenu { copyMenu(for: file) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// *Copy into attempt k*: the file as it stands in the left attempt's sandbox, into another open attempt.
    /// With two attempts on the sides, the reverse too — the right one's file into the left.
    @ViewBuilder private func copyMenu(for file: DiffFile) -> some View {
        if let left, let repo {
            ForEach(open.filter { $0.id != left.id }) { target in
                Button("Copy into \(target.name) (from \(left.name))") {
                    Task { await model.copyAttemptFile(file.path, repo: repo, from: left, to: target) }
                }
            }
            if let right, !left.isArchived {
                Divider()
                Button("Copy into \(left.name) (from \(right.name))") {
                    Task { await model.copyAttemptFile(file.path, repo: repo, from: right, to: left) }
                }
            }
        }
    }

    private func fileView(_ file: DiffFile) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(file.path)
                    .font(.scopeValue)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("+\(file.additions) −\(file.deletions)")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.secondary)
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            Divider()
            if file.isBinary {
                Text("Binary file").font(.scopeCaption).foregroundStyle(Ink.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !file.hasHunks {
                Text("No textual change").font(.scopeCaption).foregroundStyle(Ink.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MonoTextView(
                    identity: CompareIdentity(key: diffKey, path: file.path),
                    version: CompareVersion(file: file, collapsed: collapsed),
                    build: { DiffDocumentBuilder.build(file: file, collapsed: collapsed, focused: nil) },
                    onAnchorClick: { index in
                        if collapsed.contains(index) { collapsed.remove(index) } else { collapsed.insert(index) }
                    },
                    gutterWidth: DiffDocumentBuilder.gutterWidth(for: file)
                )
            }
        }
    }

    private struct CompareIdentity: Hashable {
        let key: String
        let path: String
    }

    private struct CompareVersion: Hashable {
        let file: DiffFile
        let collapsed: Set<Int>
    }

    private var diffKey: String {
        "\(group)|\(selection.left)|\(selection.right ?? 0)|\(repo?.id ?? "")|\(loadCount)"
    }

    private func loadDiff() async {
        guard let left, let repo else {
            files = []
            return
        }
        loading = true
        defer { loading = false }
        switch await model.attemptDiff(left: left, right: right, repo: repo) {
        case .success(let loaded):
            files = loaded
            error = nil
            if !loaded.contains(where: { $0.path == selectedFile }) { selectedFile = loaded.first?.path }
            collapsed = []
        case .failure(let failure):
            files = []
            error = failure.message
        }
    }

    // MARK: Keys

    /// The physical digit keys, whatever the layout prints on them.
    private static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
                                                       83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9, 82: 0]

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let digit = Self.digitKeyCodes[event.keyCode],
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        guard let next = selection.pressing(digit: digit, shift: event.modifierFlags.contains(.shift), count: attempts.count) else {
            return false
        }
        selection = next
        return true
    }
}

/// One file of the diff pane's list: its path and its counts.
private struct CompareFileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 6) {
            Text(file.path)
                .font(.scopeRow)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("+\(file.additions)")
                .font(.scopeMicro)
                .foregroundStyle(PullRequestStyle.passing)
            Text("−\(file.deletions)")
                .font(.scopeMicro)
                .foregroundStyle(PullRequestStyle.failing)
        }
    }
}

/// A local key monitor scoped to the window this view sits in: SwiftUI's `onKeyPress` only sees characters, and
/// the Compare keys are about which key, not what it prints.
private struct KeyCodeMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(for: view, handle: handle)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor final class Coordinator {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        func install(for view: NSView, handle: @escaping (NSEvent) -> Bool) {
            self.handle = handle
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let view, event.window === view.window,
                      !(event.window?.firstResponder is NSTextView) else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
