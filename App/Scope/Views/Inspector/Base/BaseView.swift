import SwiftUI
import ScopeCore
import ScopeTasks

/// The Base inspector panel (spec §4.5): repo picker, the version band — the branch in bold, the HEAD commit, how
/// far behind origin the checkout is, Pull — then Editor / Shell / Reveal and the Files / Search / History
/// sections. Which repository it shows is `AppModel.baseSubject`; the line under the picker says why, and the picker
/// pins another one for the current task, loose thread or scope.
struct BaseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let scope = model.currentScope, let subject = model.baseSubject() {
            content(scope: scope, repo: subject.repo, reason: subject.reason)
                .task(id: subject.repo.url) {
                    model.base.show(repo: subject.repo)
                    model.base.recent[scope.id] = GraphModel.key(for: subject.repo)
                }
        } else {
            ContentUnavailableView {
                Label("No repository", systemImage: "square.stack.3d.up")
            } description: {
                Text("Select a scope with at least one repository to browse its base checkout.")
            }
        }
    }

    /// The picker's tag for "no pin"; not a path, so it cannot collide with a repository (a repo scope's is `""`).
    private static let followTag = "\u{0}follow"

    private func content(scope: ScopeState, repo: RepoState, reason: BaseSubjectReason) -> some View {
        @Bindable var base = model.base
        let candidates = model.baseRepoCandidates(in: scope)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    // The path to what the panel shows, its last step being the picker.
                    // With a task selected the band above already reads "task · scope": repeating both here made
                    // two headers for one subject, so the path starts at the task.
                    Text(model.currentTask?.name ?? scope.name)
                        .font(.scopeCaption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    crumbSeparator
                    ScopePicker("Repository", selection: Binding(
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
                    .help("Pin a repository here, or follow the selection")
                    .fixedSize()
                    Spacer(minLength: 0)
                    if model.base.isFetching || model.base.isPulling {
                        ScopeSpinner(size: 12)
                    }
                    Button {
                        Task { await model.base.refreshBehind(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.icon)
                    .help("Fetch and recount")
                    .accessibilityLabel("Fetch and recount")
                }
                subjectLine(reason: reason)
                versionBand(scope: scope, repo: repo)
                HStack(spacing: 6) {
                    Button {
                        model.openInEditorOrCopy(path: repo.url.path)
                    } label: {
                        Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
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
                .buttonStyle(.scopeSecondary)
                TabStrip(selection: $base.section,
                         items: BaseSection.allCases.map { ($0, $0.rawValue) })
                    .accessibilityLabel("Section")
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
        .background(Surface.ground)
    }

    private var crumbSeparator: some View {
        Text("›")
            .font(.scopeCaption)
            .foregroundStyle(Ink.tertiary)
            .accessibilityHidden(true)
    }

    /// Why the panel is on this repository, in a sentence, with the way out of a pin next to it.
    private func subjectLine(reason: BaseSubjectReason) -> some View {
        HStack(spacing: 6) {
            Text(explanation(of: reason))
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            if reason == .pinned {
                Button("Unpin") { model.unpinBase() }
                    .buttonStyle(.scopeLink)
                    .font(.scopeCaption)
                    .help("Follow the selection again")
            }
            Spacer(minLength: 0)
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

    /// What version the checkout is at, readable at a glance: the branch in bold, the HEAD commit (short sha,
    /// subject, age — the first row of the history the panel already loads), the behind count, and Pull right
    /// there since that is what the count calls for.
    private func versionBand(scope: ScopeState, repo: RepoState) -> some View {
        let head = model.base.commits.first
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 16))
                .foregroundStyle(Ink.secondary)
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
            }
            Spacer(minLength: 4)
            Button {
                Task { await model.base.pull(repo: repo, scope: scope) }
            } label: {
                Label("Pull", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.scopeSecondary)
            .disabled(model.base.isPulling)
            .help("git pull --ff-only")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.quiet, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Fill.quiet))
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
