import SwiftUI
import ScopeCore

/// The reading column's Markdown page: an agent's last answer, a task's deliverable or its brief
/// (`ReadingContent`), with a header naming it and a *Copy as Markdown* button. Links go through the model: the
/// browser for the web, the viewer column for a file (`AppModel.openMarkdownLink`).
///
/// A measure of 720 pt at most, centred: an answer is read like a page, not like a log.
struct ReadingViewer: View {
    @Environment(AppModel.self) private var model
    var leading: AnyView?
    var trailing: AnyView?
    @State private var document = MarkdownDocument(blocks: [])

    var body: some View {
        if let content = model.inspector.reading {
            VStack(spacing: 0) {
                header(content)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let turn = content.turn, !turn.calls.isEmpty || turn.changes != nil {
                                ReadingTurnBand(turn: turn) { changes in model.openChanges(changes) }
                            }
                            MarkdownReader(document: document)
                            if let turn = content.turn, case .reply(let id) = content.kind {
                                ReadingHistoryList(turn: turn) { index in
                                    if let session = model.session(id) { model.readHistoryTurn(index, of: session) }
                                }
                            }
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        Color.clear.frame(height: 1).id(Self.endAnchor)
                    }
                    // An answer being written is read at its end, where the new lines land.
                    .onChange(of: document) {
                        if content.isLive { proxy.scrollTo(Self.endAnchor, anchor: .bottom) }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    model.openMarkdownLink(url, in: content)
                    return .handled
                })
            }
            // Parsed when the text changes, never on a redraw.
            .onChange(of: content.markdown, initial: true) { document = MarkdownDocument.parse(content.markdown) }
        }
    }

    private static let endAnchor = "end"

    private func header(_ content: ReadingContent) -> some View {
        HStack(spacing: 8) {
            if let leading { leading }
            Image(systemName: content.icon)
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
            Text(content.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if content.isLive {
                Text("writing…")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize()
            } else if let at = content.at {
                Text(at.formatted(.relative(presentation: .named)))
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(at.formatted(date: .abbreviated, time: .shortened))
            }
            CopyButton(label: "Copy as Markdown") { content.markdown }
                .help("Copy as Markdown")
            if let trailing {
                HStack(spacing: 2) { trailing }.fixedSize()
            }
        }
        .buttonStyle(.iconTight)
        .foregroundStyle(Ink.secondary)
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Surface.panel)
    }
}
