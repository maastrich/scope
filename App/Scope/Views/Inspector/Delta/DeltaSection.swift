import SwiftUI
import ScopeCore
import ScopeGit
import ScopeTasks

/// The Delta section (spec §4.4): closed, `+N −M` of the task (and the mode when it is not *Task*); open, the
/// changed files grouped by repo. The diff of the selected file is the inspector's viewer, under the sections, so the
/// list keeps its height whatever else is open. Keyboard: `j`/`k` next/previous file, `]`/`[` next/previous hunk.
///
/// The mode (Task / Uncommitted / Base vs origin) is a menu in the header: a row of tabs for a choice made once in a
/// while cost a line of height on every look. Refresh, and Commit… / Push when Settings ▸ Git asks for them, come on
/// hover; the pull request buttons the old action bar carried live in the Pull Request section.
struct DeltaSection: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var sash: SectionSash?
    @State private var showCommitSheet = false
    @FocusState private var focused: Bool
    @FocusState private var filterFocused: Bool

    var body: some View {
        @Bindable var delta = model.delta
        let task = model.currentTask
        CollapsibleSection(section: .delta, bodyHeight: bodyHeight,
                           help: "Keyboard: j / k next and previous file, ] / [ next and previous hunk",
                           command: "command.delta", sash: sash) {
            if let task { summary(task) }
        } accessories: {
            HStack(spacing: 6) {
                if delta.isLoading || delta.isActing {
                    ScopeSpinner(size: 10)
                }
                if model.isSectionOpen(.delta) {
                    HeaderPicker("Mode", selection: $delta.mode, title: Self.modeTitle(delta.mode)) {
                        Text("Task").tag(DeltaMode.task)
                        Text("Uncommitted").tag(DeltaMode.uncommitted)
                        Text("Base vs origin").tag(DeltaMode.baseVsOrigin)
                    }
                    .help(modeCaption)
                }
            }
        } actions: {
            if let task { actions(task) }
        } content: {
            if let task { content(task) }
        }
        .sheet(isPresented: $showCommitSheet) {
            if let task, let repo = model.delta.focusedRepo {
                CommitSheet(task: task, repo: repo) { message in
                    Task { await model.delta.commit(message: message, task: task) }
                }
            }
        }
    }

    // MARK: Header

    /// The delta's own numbers once it is loaded for this task, the sidebar's summaries before that — so the closed
    /// header has its counts on the first frame.
    @ViewBuilder
    private func summary(_ task: TaskState) -> some View {
        let delta = model.delta
        let loaded = delta.taskID == task.id && delta.hasLoaded
        HStack(spacing: 6) {
            if delta.mode != .task {
                Text(Self.modeTitle(delta.mode))
            }
            if delta.mode == .baseVsOrigin {
                if loaded {
                    Text("↑\(delta.ahead) ↓\(delta.behind)").font(.scopeValue)
                }
            } else if loaded {
                let summary = delta.summary
                if summary.files == 0 {
                    Text("no changes").foregroundStyle(Ink.tertiary)
                } else {
                    Text("\(summary.files) \(summary.files == 1 ? "file" : "files")")
                    DeltaCounts(additions: summary.additions, deletions: summary.deletions)
                }
            } else {
                let summaries = task.activeSandboxes.compactMap { task.summary(for: $0) }
                DeltaCounts(additions: summaries.reduce(0) { $0 + $1.additions },
                            deletions: summaries.reduce(0) { $0 + $1.deletions })
            }
        }
    }

    @ViewBuilder
    private func actions(_ task: TaskState) -> some View {
        let delta = model.delta
        if model.config.preferences.showGitActions {
            let repo = delta.focusedRepo
            let dirty = repo.map { task.summary(for: $0)?.isDirty ?? true } ?? false
            Button {
                showCommitSheet = true
            } label: {
                Image(systemName: "circle.circle")
            }
            .disabled(repo == nil || delta.isActing || !dirty)
            .help(dirty ? "Commit… — git add -A && git commit in the sandbox" : "Nothing to commit")
            .usageID("commit", label: "Commit")
            .accessibilityLabel("Commit")
            Button {
                Task { await model.delta.push(task: task) }
            } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .disabled(repo == nil || delta.isActing)
            .help("Push — git push -u origin \(task.branch)")
            .usageID("push", label: "Push")
            .accessibilityLabel("Push")
        }
        Button {
            task.refresh()
            Task { await model.delta.load(task: task) }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
        .usageID("refresh", label: "Refresh")
        .accessibilityLabel("Refresh the changes")
    }

    // MARK: Body

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        let delta = model.delta
        Group {
            if delta.mode == .baseVsOrigin {
                DeltaBaseVsOriginView(task: task)
            } else if !delta.hasLoaded, delta.isLoading {
                DeltaSkeleton()
            } else if delta.orderedFiles.isEmpty {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text("No changes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                    ForEach(delta.repos.filter { $0.error != nil }) { repo in
                        Text("\(repo.repo.sandboxLabel(scopeName: task.record.scopeName)): \(repo.error ?? "")")
                            .font(.scopeCaption)
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DeltaFileList(task: task, filterFocused: $filterFocused)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Surface.ground)
        .modifier(DeltaKeyboard(focused: $focused, isSuspended: filterFocused))
        .task(id: model.inspector.focusRequest) {
            guard model.inspector.takeFocus(for: .delta) else { return }
            // The body has just appeared when ⌘D opened the section: give it a turn to become focusable.
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
    }

    static func modeTitle(_ mode: DeltaMode) -> String {
        switch mode {
        case .task: "Task"
        case .uncommitted: "Uncommitted"
        case .baseVsOrigin: "Base vs origin"
        }
    }

    private var modeCaption: String {
        switch model.delta.mode {
        case .task: "The task branch vs its merge-base with the default branch"
        case .uncommitted: "The working tree vs HEAD"
        case .baseVsOrigin: "The base vs \(model.delta.repos.first?.delta?.base ?? "origin")"
        }
    }
}

/// `j`/`k` next/previous file, `]`/`[` next/previous hunk — on the file list and on the diff in the viewer, so the
/// keys work wherever the eye is. Moving to a file opens its diff.
struct DeltaKeyboard: ViewModifier {
    @Environment(AppModel.self) private var model
    var focused: FocusState<Bool>.Binding
    /// A text field inside (the path filter) is taking the keys.
    var isSuspended = false

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onKeyPress(characters: CharacterSet(charactersIn: "jk[]"), phases: .down) { press in
                guard !isSuspended else { return .ignored }
                switch press.characters {
                case "j":
                    model.delta.selectNextFile(1)
                    model.inspector.show(.diff)
                case "k":
                    model.delta.selectNextFile(-1)
                    model.inspector.show(.diff)
                case "]": model.delta.focusHunk(1)
                case "[": model.delta.focusHunk(-1)
                default: return .ignored
                }
                return .handled
            }
    }
}

/// Grey bars standing in for the file list while the first load runs.
struct DeltaSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Fill.quiet)
                    .frame(width: index == 0 ? 120 : CGFloat(180 + (index * 37) % 120), height: 12)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
