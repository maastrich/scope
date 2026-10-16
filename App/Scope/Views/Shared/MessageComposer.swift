import SwiftUI
import ScopeControl

/// A message to a thread, typed outside its terminal: ↩ sends, ⇧↩ (or ⌥↩) starts a new line, Esc gives up. The
/// palette's *Ask Orchestrator…* and the sidebar's inline reply both use it, so the two keys mean the same in both.
///
/// With `mentions`, an `@` at the end of the draft offers those tasks (`MentionQuery`): ↑↓ pick one, Tab or ↩ complete
/// it to `@task:<slug> `, which Scope expands into the task's context when the message goes.
struct MessageComposer: View {
    @Binding var text: String
    let placeholder: String
    var font: Font = .scopeBody
    /// Fixed: a `TextEditor` has no height of its own to grow from; a longer message scrolls.
    var height: CGFloat = 60
    /// The tasks `@` may name, recent first; empty for a field without completion.
    var mentions: [MentionQuery.Candidate] = []
    let onSend: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    private var query: MentionQuery? {
        guard !mentions.isEmpty, let query = MentionQuery.active(in: text), query.kind == .task else { return nil }
        return query
    }

    private var suggestions: [MentionQuery.Candidate] {
        query?.matches(in: mentions) ?? []
    }

    private func complete(_ candidate: MentionQuery.Candidate) {
        guard let query else { return }
        text = query.completing(text, with: candidate.slug)
        highlighted = 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            editor
            if !suggestions.isEmpty {
                MentionSuggestions(candidates: suggestions, highlighted: highlighted, pick: complete)
            }
        }
        .onChange(of: text) { _, _ in highlighted = 0 }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .frame(height: height)
                .focused($focused)
                .accessibilityLabel(placeholder)
                .onKeyPress(.return, phases: .down) { press in
                    // ⇧↩ and ⌥↩ fall through to the text view, which inserts the line break.
                    guard press.modifiers.isDisjoint(with: [.shift, .option]) else { return .ignored }
                    let offered = suggestions
                    if !offered.isEmpty {
                        complete(offered[min(highlighted, offered.count - 1)])
                        return .handled
                    }
                    onSend()
                    return .handled
                }
                .onKeyPress(.tab) {
                    let offered = suggestions
                    guard !offered.isEmpty else { return .ignored }
                    complete(offered[min(highlighted, offered.count - 1)])
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlighted = max(0, highlighted - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    let offered = suggestions
                    guard !offered.isEmpty else { return .ignored }
                    highlighted = min(offered.count - 1, highlighted + 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !suggestions.isEmpty {
                        // Closing the list: the `@` stays as typed, and a second Esc gives the message up.
                        text += " "
                        return .handled
                    }
                    onCancel()
                    return .handled
                }
        }
        .task {
            // The terminal (or the sidebar list) holds the keyboard: take it once the editor is in the window.
            focused = true
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }
}

/// The tasks offered under the field for the `@` being typed: slug, name, a mark for an archived one.
private struct MentionSuggestions: View {
    let candidates: [MentionQuery.Candidate]
    let highlighted: Int
    let pick: (MentionQuery.Candidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                Button {
                    pick(candidate)
                } label: {
                    HStack(spacing: 6) {
                        Text("@task:\(candidate.slug)")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Text(candidate.name)
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                        if candidate.archived {
                            Text("archived")
                                .font(.system(size: 10))
                                .foregroundStyle(Ink.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == highlighted ? Fill.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .usageID("mention-task", label: "Complete a task mention")
            }
            Text("↹ or ↩ completes · the task's brief, branch, PR and last answer go with the message")
                .font(.system(size: 10))
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 3)
        }
        .padding(4)
        .background(Surface.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Surface.stroke))
        .accessibilityLabel("Task mentions")
    }
}
