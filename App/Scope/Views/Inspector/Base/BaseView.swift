import SwiftUI

/// The Base inspector panel (spec §4.5): repo picker, header (branch, behind N, Pull, Open in Editor,
/// shell, Reveal), then Files / Search / History.
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
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("Repository", selection: Binding(
                        get: { model.base.pickedRepo[scope.id] ?? repo.id },
                        set: { model.base.pickedRepo[scope.id] = $0 }
                    )) {
                        ForEach(scope.repos) { candidate in
                            Text(candidate.shortName).tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    if let branch = repo.branchLabel {
                        Text(branch)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    }
                    behindBadge
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
                HStack(spacing: 6) {
                    Button {
                        Task { await model.base.pull(repo: repo, scope: scope) }
                    } label: {
                        Label("Pull", systemImage: "arrow.down.to.line")
                    }
                    .disabled(model.base.isPulling)
                    .help("git pull --ff-only")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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
