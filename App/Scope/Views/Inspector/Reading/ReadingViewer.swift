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
                ScrollView {
                    MarkdownReader(document: document)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
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
            if let at = content.at {
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
