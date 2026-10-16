import SwiftUI
import ScopeCore
import ScopeTasks

/// One Inbox item: what it is (the thread's state shape, or the pull request's), where (task · thread), what it says
/// in one line, how long ago, and its actions — on hover or when selected, so a long list stays quiet. Drawn by the
/// sheet and, `compact`, by the menu bar extra, which keeps Reply and Open.
struct InboxRow: View {
    @Environment(AppModel.self) private var model
    let item: Inbox.Item
    var selected = false
    var compact = false
    /// The menu bar extra closes itself before an action that brings the window up.
    var onOpen: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                InboxKindMark(kind: item.kind)
                    .frame(width: 14, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        title
                        Spacer(minLength: 6)
                        if !showsActions {
                            InboxAge(date: item.at)
                        }
                    }
                    if let detail = item.detail {
                        Text(detail)
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(compact ? 1 : 2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(detail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsActions {
                    InboxActions(item: item, compact: compact, onOpen: onOpen)
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 8)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { open() }
            .onTapGesture { model.inbox.selected = item.id }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if model.inbox.replyingTo == item.id, let thread = item.threadID {
                InboxReplyField(item: item, thread: thread, compact: compact)
                    .padding(.leading, compact ? 32 : 34)
                    .padding(.trailing, compact ? 8 : 10)
                    .padding(.bottom, 8)
            }
        }
    }

    private var showsActions: Bool { hovering || selected }

    private var title: some View {
        HStack(spacing: 5) {
            Text(item.title)
                .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if let task = taskName {
                Text(task)
                    .font(.system(size: compact ? 11 : 11.5))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
        .truncationMode(.tail)
    }

    /// A thread item names its task after the thread, unless the thread is called after its task already (the first
    /// thread of a task is); a task item's title already is the task.
    private var taskName: String? {
        guard item.threadID != nil, let id = item.taskID, let name = model.task(id)?.name, name != item.title else { return nil }
        return name
    }

    private var background: Color {
        if selected { return Fill.selectedTint }
        return hovering ? Fill.hover : .clear
    }

    private func open() {
        onOpen?()
        model.openInboxItem(item)
    }
}

/// The leading mark: a thread item draws its thread's state dot, so the inbox reads like the sidebar; a task item the
/// pull request glyph in its checks colour, or the archive box.
struct InboxKindMark: View {
    let kind: Inbox.Kind

    var body: some View {
        switch kind {
        case .question: StateDot(state: .waiting(reason: .input))
        case .permission: StateDot(state: .waiting(reason: .permission))
        case .reply: StateDot(state: .done)
        case .failure: StateDot(state: .failed)
        case .readyToMerge: glyph("arrow.triangle.pull", PullRequestStyle.passing)
        case .checksFailing: glyph("xmark.circle", PullRequestStyle.failing)
        case .archivedOnMerge: glyph("archivebox", Ink.tertiary)
        }
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
    }
}

/// `now`, `4m`, `2h`, `3d`: a column of ages reads at a glance where "4 minutes ago" would wrap.
struct InboxAge: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.label(date, now: context.date))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Ink.tertiary)
                .help(date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    static func label(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// The actions of one item, as icon buttons with their key in the help. The menu bar extra keeps Reply and Open.
struct InboxActions: View {
    @Environment(AppModel.self) private var model
    let item: Inbox.Item
    var compact = false
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            if item.kind.isThreadItem {
                action("arrowshape.turn.up.left", "Reply (r)", id: "reply") { model.inbox.replyingTo = item.id }
            }
            if !compact {
                switch item.kind {
                case .checksFailing:
                    if model.checkFailureThread(for: item) != nil {
                        action("paperplane", "Send the failing checks to the thread (s)", id: "send-checks") {
                            model.sendInboxCheckFailures(item)
                        }
                    }
                    pullRequestButton
                case .readyToMerge:
                    pullRequestButton
                    action("archivebox", "Archive Task (a)", id: "archive") { model.archiveInboxTask(item) }
                case .archivedOnMerge:
                    pullRequestButton
                default:
                    EmptyView()
                }
                action("checkmark", item.kind.isThreadItem ? "Mark as Read (e)" : "Done (e)", id: "mark-read") {
                    model.markInboxItemRead(item)
                }
            }
            action(item.kind == .archivedOnMerge ? "arrow.uturn.backward" : "arrow.up.forward.app",
                   item.kind == .archivedOnMerge ? "Restore Task (↩)" : "Open (↩)", id: "open") {
                onOpen?()
                model.openInboxItem(item)
            }
        }
        .buttonStyle(.iconTight)
        .foregroundStyle(Ink.secondary)
    }

    @ViewBuilder private var pullRequestButton: some View {
        if item.pullRequestURL != nil {
            action("arrow.up.right.square", "Open Pull Request in Browser (o)", id: "open-pr") {
                model.openInboxPullRequest(item)
            }
        }
    }

    private func action(_ symbol: String, _ help: String, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .help(help)
        .accessibilityLabel(help)
        .usageID(id, label: help)
    }
}

/// The reply field under a thread item: the same composer and the same send as the sidebar's reply.
struct InboxReplyField: View {
    @Environment(AppModel.self) private var model
    let item: Inbox.Item
    let thread: ThreadID
    var compact = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MessageComposer(text: $draft, placeholder: "Reply to \(item.title)…", font: .system(size: 12),
                            height: compact ? 44 : 54) {
                guard model.replyFromInbox(draft, to: item) else { return }
                model.inbox.replyingTo = nil
            } onCancel: {
                model.inbox.replyingTo = nil
            }
            .scopeTextBox(focused: true, inset: 2)
            Text("↩ send · ⇧↩ new line · esc")
                .font(.system(size: 10))
                .foregroundStyle(Ink.tertiary)
        }
    }
}
