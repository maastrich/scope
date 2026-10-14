import SwiftUI
import ScopeCore
import ScopeTasks

/// The Base section (spec §4.5): the version the base checkout is at. Closed, the branch and how far behind origin it
/// is; the repository picker and Pull — when there is something to pull — stay in the header either way, since they
/// are what the count calls for. Open, the HEAD commit and why the column shows this repository.
///
/// Which repository it is comes from `AppModel.baseSubject`; picking another pins it for the current task, loose
/// thread or scope, and the pin shows in the header with the way out of it. Fetch, Open in Editor, Open a Shell and
/// Reveal come on hover — they used to be a row of buttons that always took its height.
struct BaseSection: View {
    @Environment(AppModel.self) private var model
    let bodyHeight: Double?
    var onNatural: (Double) -> Void

    /// The picker's tag for "no pin"; not a path, so it cannot collide with a repository (a repo scope's is `""`).
    private static let followTag = "\u{0}follow"

    var body: some View {
        let scope = model.currentScope
        let subject = model.baseSubject()
        CollapsibleSection(section: .base, bodyHeight: bodyHeight, unavailable: "no repository", onNatural: onNatural) {
            if let subject { summary(repo: subject.repo) }
        } accessories: {
            if let scope, let subject { accessories(scope: scope, repo: subject.repo, reason: subject.reason) }
        } actions: {
            if let scope, let subject { actions(scope: scope, repo: subject.repo) }
        } content: {
            if let subject { content(repo: subject.repo, reason: subject.reason) }
        }
    }

    // MARK: Header

    private func summary(repo: RepoState) -> some View {
        HStack(spacing: 6) {
            Text(repo.branchLabel ?? "…")
                .font(.system(size: 11, design: .monospaced))
                .truncationMode(.middle)
            if let behind = model.base.behind, behind > 0 {
                Text("behind \(behind)")
                    .foregroundStyle(Color("WarningText"))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func accessories(scope: ScopeState, repo: RepoState, reason: BaseSubjectReason) -> some View {
        let candidates = model.baseRepoCandidates(in: scope)
        HStack(spacing: 4) {
            if model.base.isFetching || model.base.isPulling {
                ScopeSpinner(size: 10)
            }
            if reason == .pinned {
                Button {
                    model.unpinBase()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.iconTight)
                .help("Pinned here — click to follow the selection again")
                .accessibilityLabel("Unpin the repository")
            }
            HeaderPicker("Repository", selection: Binding(
                get: { reason == .pinned ? repo.id : Self.followTag },
                set: { id in
                    if id == Self.followTag {
                        model.unpinBase()
                    } else if let picked = scope.repo(relativePath: id) {
                        model.pinBase(picked, in: scope)
                    }
                }
            ), title: repo.shortName) {
                Text("Follow Selection").tag(Self.followTag)
                Section(model.currentTask == nil ? "Repositories of the scope" : "Repositories of the task") {
                    ForEach(candidates.own) { candidate in
                        Text(candidate.shortName).tag(candidate.id)
                    }
                }
                if !candidates.others.isEmpty {
                    Section("Other repositories") {
                        ForEach(candidates.others) { candidate in
                            Text(candidate.shortName).tag(candidate.id)
                        }
                    }
                }
            }
            .help("\(explanation(of: reason)) Pick another to pin it here.")
            .fixedSize()
            if let behind = model.base.behind, behind > 0 {
                pullButton(scope: scope, repo: repo)
            }
        }
    }

    private func pullButton(scope: ScopeState, repo: RepoState) -> some View {
        Button {
            Task { await model.base.pull(repo: repo, scope: scope) }
        } label: {
            Label("Pull", systemImage: "arrow.down.to.line")
        }
        .buttonStyle(.headerChip)
        .disabled(model.base.isPulling)
        .help("git pull --ff-only")
    }

    @ViewBuilder
    private func actions(scope: ScopeState, repo: RepoState) -> some View {
        Button {
            Task { await model.base.refreshBehind(force: true) }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Fetch and recount")
        .accessibilityLabel("Fetch and recount")
        Button {
            model.openInEditorOrCopy(path: repo.url.path)
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .help("Open the base checkout in the editor (⌥-click copies the path)")
        .accessibilityLabel("Open in Editor")
        Button {
            Task { await model.openBaseShell(repo: repo, in: scope) }
        } label: {
            Image(systemName: "terminal")
        }
        .help("Open a shell here (secondary terminal in the base)")
        .accessibilityLabel("Open a shell in the base")
        Button {
            Reveal.inFinder(repo.url)
        } label: {
            Image(systemName: "folder")
        }
        .help("Reveal in Finder")
        .accessibilityLabel("Reveal in Finder")
    }

    // MARK: Body

    /// The branch in bold with the behind count, the HEAD commit (short sha, subject, age — the first row of the
    /// history already loaded), and in a caption why this repository.
    private func content(repo: RepoState, reason: BaseSubjectReason) -> some View {
        let head = model.base.commits.first
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
                Text(repo.branchLabel ?? "…")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(repo.branchLabel ?? "Branch unknown")
                behindBadge
            }
            HStack(spacing: 6) {
                if let head {
                    Text(head.short)
                        .font(.scopeValue)
                        .foregroundStyle(Ink.secondary)
                    Text(head.subject)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("· \(head.date.formatted(.relative(presentation: .named)))")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                } else if model.base.isLoadingHistory {
                    Text("Loading HEAD…")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                } else {
                    Text("No commit yet")
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .help(head.map { "\($0.sha)\n\($0.subject)\n\($0.author), \($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            Text(explanation(of: reason))
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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

    private func explanation(of reason: BaseSubjectReason) -> String {
        switch reason {
        case .pinned: "Base checkout · you pinned it here."
        case .selection: "Base checkout · selected in the sidebar."
        case .thread: "Base checkout · \(model.currentThread.map(model.displayTitle(for:)) ?? "the thread") is working in it."
        case .delta: "Base checkout · the file open in Delta belongs to it."
        case .task: "Base checkout · first repository of the task."
        case .recent: "Base checkout · last shown in this scope."
        case .first: "Base checkout · first repository of the scope."
        }
    }
}
