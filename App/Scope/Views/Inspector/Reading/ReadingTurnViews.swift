import SwiftUI
import ScopeCore

/// Over a reply: the tools its turn ran and what the turn changed, each a folded row the reader opens when the
/// answer alone does not say enough. Nothing here is the agent's prose — it is what the hooks and the checkpoint
/// reported, so a tool the app has never heard of still shows as a name, a target and a time.
struct ReadingTurnBand: View {
    let turn: ReadingTurn
    let onOpenChanges: (ReadingTurn.Changes) -> Void
    @State private var callsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !turn.calls.isEmpty {
                ReadingFold(isOpen: $callsOpen, title: turn.historyIndex == nil ? "This turn" : "That turn",
                            detail: "\(turn.calls.count) \(turn.calls.count == 1 ? "tool" : "tools")") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(turn.calls) { call in
                            HStack(spacing: 8) {
                                Text(call.name)
                                    .foregroundStyle(Ink.secondary)
                                    .frame(width: 64, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(call.target ?? "")
                                    .foregroundStyle(Ink.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                if let ms = call.durationMs {
                                    Text(Self.duration(ms))
                                        .foregroundStyle(Ink.tertiary)
                                        .fixedSize()
                                }
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if let changes = turn.changes {
                Button {
                    onOpenChanges(changes)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.tertiary)
                        Text("Changes")
                            .fontWeight(.medium)
                        if changes.additions + changes.deletions == 0 {
                            Text("· nothing").foregroundStyle(Ink.tertiary)
                        } else {
                            Text("+\(changes.additions)").foregroundStyle(ThreadStateStyle.running)
                            Text("−\(changes.deletions)").foregroundStyle(ThreadStateStyle.failed)
                            if changes.repos.count > 1 {
                                Text("· \(changes.repos.count) sandboxes").foregroundStyle(Ink.tertiary)
                            }
                        }
                        Spacer(minLength: 4)
                        Text("checkpoint \(changes.number)")
                            .foregroundStyle(Ink.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.scopeMicro)
                            .foregroundStyle(Ink.tertiary)
                    }
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(Surface.panel, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Surface.stroke))
                }
                .buttonStyle(.plain)
                .help("Show what this turn changed, against the sandbox now")
            }
        }
    }

    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        return "\(ms / 60_000) m \((ms % 60_000) / 1000) s"
    }
}

/// Under a reply: the session's earlier turns, from its transcript, one line each; a click reads that turn, the
/// latest answer goes back on top. Absent while the transcript has not been read; a word when it cannot be.
struct ReadingHistoryList: View {
    let turn: ReadingTurn
    let onSelect: (Int?) -> Void
    @State private var open = true

    var body: some View {
        if turn.historyUnavailable {
            Text("The session's earlier turns could not be read from its transcript.")
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
        } else if !turn.history.isEmpty {
            ReadingFold(isOpen: $open, title: "Earlier in this session", detail: "\(turn.history.count) \(turn.history.count == 1 ? "turn" : "turns")") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(turn.history.reversed()) { item in
                        let selected = turn.historyIndex == item.id
                        Button {
                            onSelect(selected ? nil : item.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("turn \(item.id + 1)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Ink.tertiary)
                                    .frame(width: 48, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.prompt)
                                        .foregroundStyle(Ink.primary)
                                        .lineLimit(1)
                                    if !item.reply.isEmpty {
                                        Text(item.reply)
                                            .foregroundStyle(Ink.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(item.tools == 0 ? "" : "\(item.tools) \(item.tools == 1 ? "tool" : "tools")")
                                    .foregroundStyle(Ink.tertiary)
                                    .fixedSize()
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? Fill.quiet : .clear, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(selected ? "Back to the latest answer" : "Read this turn")
                    }
                }
                .padding(4)
            }
        }
    }
}

/// A folded row: a chevron, a title, a detail, and the content under it when open.
struct ReadingFold<Content: View>: View {
    @Binding var isOpen: Bool
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.scopeMicro)
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title).fontWeight(.medium)
                    Text("· \(detail)").foregroundStyle(Ink.tertiary)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Divider()
                content
            }
        }
        .background(Surface.panel, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Surface.stroke))
    }
}
