import SwiftUI
import ScopeGit
import ScopeTasks

/// The Delta inspector panel (spec §4.4, design §6): mode row, summary, file list grouped by repo, the
/// unified diff of the selected file, and the action bar. Follows `AppModel.currentTask`; a scope-level
/// thread shows the "No task" state. Keyboard: `j`/`k` next/previous file, `]`/`[` next/previous hunk.
struct DeltaView: View {
    @Environment(AppModel.self) private var model
    @State private var showCommitSheet = false
    @FocusState private var focused: Bool
    @FocusState private var filterFocused: Bool

    var body: some View {
        Group {
            if let task = model.currentTask {
                content(task)
                    .task(id: LoadKey(task: task.id, mode: model.delta.mode, tick: task.changeTick)) {
                        await model.delta.load(task: task)
                    }
            } else {
                ContentUnavailableView {
                    Label("No task", systemImage: "plus.forwardslash.minus")
                } description: {
                    Text("Select a task or one of its threads to see its delta. Scope-level threads work in the base checkouts and have no sandbox.")
                }
            }
        }
    }

    private struct LoadKey: Hashable {
        let task: TaskID
        let mode: DeltaMode
        let tick: Int
    }

    @ViewBuilder
    private func content(_ task: TaskState) -> some View {
        @Bindable var delta = model.delta
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $delta.mode) {
                    Text("Task").tag(DeltaMode.task)
                    Text("Uncommitted").tag(DeltaMode.uncommitted)
                    Text("Base vs origin").tag(DeltaMode.baseVsOrigin)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Spacer(minLength: 0)
                if delta.isLoading || delta.isActing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    task.refresh()
                    Task { await model.delta.load(task: task) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 6, trailing: 14))

            summaryRow(task)
                .padding(EdgeInsets(top: 2, leading: 14, bottom: 8, trailing: 14))

            Divider()
            if delta.mode == .baseVsOrigin {
                DeltaBaseVsOriginView(task: task)
            } else if !delta.hasLoaded, delta.isLoading {
                DeltaSkeleton()
            } else if delta.orderedFiles.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No changes")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(delta.repos.filter { $0.error != nil }) { repo in
                        Text("\(repo.repo.name): \(repo.error ?? "")")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                DeltaFileList(task: task, filterFocused: $filterFocused)
                    .frame(maxHeight: 300)
                Divider()
                if let ref = delta.selectedFile, let file = delta.file(ref), let repo = delta.taskRepo(ref.repo) {
                    DiffView(task: task, repo: repo, ref: ref, file: file)
                } else {
                    Spacer()
                }
            }
            Divider()
            DeltaActionBar(task: task, showCommitSheet: $showCommitSheet)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(characters: CharacterSet(charactersIn: "jk[]"), phases: .down) { press in
            guard !filterFocused else { return .ignored }
            switch press.characters {
            case "j": model.delta.selectNextFile(1)
            case "k": model.delta.selectNextFile(-1)
            case "]": model.delta.focusHunk(1)
            case "[": model.delta.focusHunk(-1)
            default: return .ignored
            }
            return .handled
        }
        .sheet(isPresented: $showCommitSheet) {
            if let repo = model.delta.focusedRepo {
                CommitSheet(task: task, repo: repo) { message in
                    Task { await model.delta.commit(message: message, task: task) }
                }
            }
        }
    }

    /// Branch, mode caption and counts. The ring shows when the panel has keyboard focus (j/k/[/] work).
    private func summaryRow(_ task: TaskState) -> some View {
        let delta = model.delta
        return keyboardHint(HStack(spacing: 6) {
            Text(task.branch)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(modeCaption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "keyboard")
                .font(.system(size: 10))
                .foregroundStyle(focused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                .accessibilityLabel(focused ? "Delta panel has keyboard focus" : "Click the panel for keyboard navigation")
            if delta.mode == .baseVsOrigin {
                Text("↑\(delta.ahead) ↓\(delta.behind)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                let summary = delta.summary
                Text("\(summary.files) \(summary.files == 1 ? "file" : "files")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                DeltaCounts(additions: summary.additions, deletions: summary.deletions)
            }
        })
    }

    private func keyboardHint(_ row: some View) -> some View {
        row
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(focused ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1))
            .padding(.horizontal, -6)
            .padding(.vertical, -3)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .help("Keyboard: j / k next and previous file, ] / [ next and previous hunk (click to focus the panel)")
    }

    private var modeCaption: String {
        switch model.delta.mode {
        case .task: "vs merge-base with the default branch"
        case .uncommitted: "working tree vs HEAD"
        case .baseVsOrigin: "vs \(model.delta.repos.first?.delta?.base ?? "origin")"
        }
    }
}

/// Grey bars standing in for the file list while the first load runs.
struct DeltaSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: index == 0 ? 120 : CGFloat(180 + (index * 37) % 120), height: 12)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
