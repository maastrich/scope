import SwiftUI

/// The Base inspector panel (spec §4.5): repo picker, the version band — the branch in bold, the HEAD commit, how
/// far behind origin the checkout is, Pull — then Editor / Shell / Reveal and the Files / Search / History
/// sections. The picker offers the task's repositories while a task is selected, every repo of the scope otherwise.
struct BaseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let scope = model.currentScope, let repo = model.baseRepo {
            content(scope: scope, repo: repo)
                .task(id: repo.url) { model.base.show(repo: repo) }
        } else {
            ContentUnavailableView {
                Label("No repository", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a scope with at least one repository to browse its base checkout.")
            }
        }
    }

    private func content(scope: ScopeState, repo: RepoState) -> some View {
        @Bindable var base = model.base
        let candidates = model.baseRepoCandidates(in: scope)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("Repository", selection: Binding(
                        get: { model.base.pickedRepo[scope.id] ?? repo.id },
                        set: { model.base.pickedRepo[scope.id] = $0 }
                    )) {
                        ForEach(candidates) { candidate in
                            Text(candidate.shortName).tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help(model.currentTask == nil ? "The repositories of the scope" : "The repositories of the task")
                    Text("base checkout")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if model.base.isFetching || model.base.isPulling {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await model.base.refreshBehind(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Fetch and recount")
                    .accessibilityLabel("Fetch and recount")
                }
                versionBand(scope: scope, repo: repo)
                HStack(spacing: 6) {
                    Button {
                        model.openInEditorOrCopy(path: repo.url.path)
                    } label: {
                        Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .disabled(model.config.preferences.editor == nil)
                    .help("Open the base checkout in the editor (⌥-click copies the path)")
                    Button {
                        Task { await model.openBaseShell(repo: repo, in: scope) }
                    } label: {
                        Label("Shell", systemImage: "terminal")
                    }
                    .help("Open a shell here (secondary terminal in the base)")
                    Button {
                        Reveal.inFinder(repo.url)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                Picker("Section", selection: $base.section) {
                    ForEach(BaseSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
            Divider()
            switch model.base.section {
            case .files: BaseFilesView()
            case .search: BaseSearchView()
            case .history: BaseHistoryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// What version the checkout is at, readable at a glance: the branch in bold, the HEAD commit (short sha,
    /// subject, age — the first row of the history the panel already loads), the behind count, and Pull right
    /// there since that is what the count calls for.
    private func versionBand(scope: ScopeState, repo: RepoState) -> some View {
        let head = model.base.commits.first
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(repo.branchLabel ?? "…")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(repo.branchLabel ?? "Branch unknown")
                    behindBadge
                }
                HStack(spacing: 6) {
                    if let head {
                        Text(head.short)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(head.subject)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("· \(head.date.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    } else if model.base.isLoadingHistory {
                        Text("Loading HEAD…")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("No commit yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .help(head.map { "\($0.sha)\n\($0.subject)\n\($0.author), \($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
            Spacer(minLength: 4)
            Button {
                Task { await model.base.pull(repo: repo, scope: scope) }
            } label: {
                Label("Pull", systemImage: "arrow.down.to.line")
            }
            .controlSize(.small)
            .disabled(model.base.isPulling)
            .help("git pull --ff-only")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var behindBadge: some View {
        if let behind = model.base.behind {
            Text(behind == 0 ? "up to date" : "behind \(behind)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(behind == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color("WarningText")))
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background((behind == 0 ? Color.primary : Color("WarningText")).opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .help(behind == 0 ? "Nothing new on origin" : "\(behind) commits on origin not in the base")
        }
    }
}
