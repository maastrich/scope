import SwiftUI

/// Read-only viewer: monospace lines with line numbers; scrolls to `BaseModel.targetLine`.
/// No syntax colouring in this pass.
struct BaseFileViewer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let base = model.base
        Group {
            switch base.content {
            case nil:
                placeholder("Select a file to read it")
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message):
                placeholder(message)
            case .text(let text):
                lines(text, path: base.selectedPath ?? "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lines(_ text: String, path: String) -> some View {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        let width = CGFloat(String(rows.count).count) * 7.5 + 12
        let target = model.base.targetLine
        return VStack(spacing: 0) {
            HStack {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(rows.count) lines").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: width, alignment: .trailing)
                                Text(String(row))
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .frame(height: 17)
                            .background(target == index + 1 ? Color.accentColor.opacity(0.14) : .clear)
                            .id(index + 1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { if let target { proxy.scrollTo(target, anchor: .center) } }
                .onChange(of: target) { _, line in
                    if let line { proxy.scrollTo(line, anchor: .center) }
                }
            }
        }
    }
}
