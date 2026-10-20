import SwiftUI
import ScopeAdapters
import ScopeCore

/// What a Claude Code thread is asking, over its terminal while it waits (`ClaudePendingRequests.current`): the
/// command, file, URL or MCP tool a permission is for with the rules Claude Code offers to remember, a question with
/// its options, a plan, an MCP server's form. Allow, Deny and the options type the answer into the terminal
/// (`AppModel.answerPendingRequest`), each a named, explicit gesture; a plan or a form is answered at the terminal.
///
/// Sits at the top of the terminal, which keeps its own dialog at the bottom, and follows the terminal palette as
/// `ThreadBanner` does. ✕ hides it for this request.
struct PendingRequestCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let session: ThreadSession
    let request: ClaudePendingRequest
    @Binding var dismissed: String?
    /// Per question, the options picked so far (multiple choice, or several questions).
    @State private var picked: [Int: Set<Int>] = [:]
    @State private var refusal: String?

    private var terminalIsDark: Bool {
        model.config.preferences.terminalAppearance == .alwaysDark || colorScheme == .dark
    }

    private var answerable: Bool { ClaudeDialogAnswer.isAnswerable(request) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            if let refusal {
                Text(refusal)
                    .font(.scopeCaption)
                    .foregroundStyle(PullRequestStyle.failing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Surface.stroke))
        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
        .environment(\.colorScheme, terminalIsDark ? .dark : .light)
        .frame(maxWidth: 720)
        .onChange(of: request.id) {
            picked = [:]
            refusal = nil
        }
        .usageArea("thread.pending")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StateDot(state: .waiting(reason: request.kind == .permission ? .permission : .input))
            Text(title)
                .font(.scopeTitle)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if let agent = request.agentType {
                Text("sub-agent \(agent)")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                dismissed = request.id
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.iconTight)
            .foregroundStyle(Ink.tertiary)
            .help("Hide — answer at the terminal")
            .usageID("dismiss", label: "Hide the pending request")
        }
    }

    private var title: String {
        switch request.kind {
        case .permission:
            if let tool = request.mcpTool { return "Asks to use \(tool)" + (request.mcpServer.map { " on \($0)" } ?? "") }
            return "Asks for a permission" + (request.tool.map { " · \($0)" } ?? "")
        case .question:
            return request.questions.count == 1 ? "Asks a question" : "Asks \(request.questions.count) questions"
        case .plan:
            return "Proposes a plan"
        case .elicitation:
            return (request.mcpServer.map { "\($0)" } ?? "An MCP server") + " asks for input"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch request.kind {
        case .permission: permission
        case .question: questions
        case .plan: plan
        case .elicitation: elicitation
        }
    }

    @ViewBuilder
    private var permission: some View {
        if let command = request.command {
            code(command)
        } else if let path = request.filePath {
            detailLine(path + (request.edit.map { " · \($0)" } ?? ""), mono: true)
        } else if let url = request.url {
            detailLine(url, mono: true)
        } else if let query = request.query {
            detailLine("Search the web for \"\(query)\"")
        }
        if let summary = request.summary {
            detailLine(summary)
        }
        if !request.suggestions.isEmpty {
            Text("Claude Code can remember: " + request.suggestions.joined(separator: " · "))
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let header = question.header {
                            Text(header.uppercased())
                                .font(.scopeMicro)
                                .foregroundStyle(Ink.tertiary)
                        }
                        Text(question.question)
                            .font(.scopeBody)
                            .foregroundStyle(Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if question.multiSelect {
                            Text("several choices")
                                .font(.scopeCaption)
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        optionRow(question: index, option: optionIndex, label: option.label, detail: option.description,
                                  multiSelect: question.multiSelect)
                    }
                }
            }
        }
    }

    /// A single question with a single choice answers on click; otherwise a click picks, and Submit answers.
    private var answersOnClick: Bool {
        request.questions.count == 1 && request.questions.first?.multiSelect == false
    }

    private func optionRow(question: Int, option: Int, label: String, detail: String?, multiSelect: Bool) -> some View {
        let isPicked = picked[question]?.contains(option) == true
        return Button {
            guard answerable else { return }
            if answersOnClick {
                answer(.choose([[option]]))
            } else if multiSelect {
                picked[question, default: []].formSymmetricDifference([option])
            } else {
                picked[question] = [option]
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(option + 1)")
                    .font(.scopeValue)
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 12, alignment: .trailing)
                if !answersOnClick {
                    Image(systemName: multiSelect ? (isPicked ? "checkmark.square.fill" : "square")
                          : (isPicked ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(isPicked ? Color.accentColor : Ink.tertiary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.scopeBody)
                        .foregroundStyle(Ink.primary)
                    if let detail {
                        Text(detail)
                            .font(.scopeCaption)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionButtonStyle(picked: isPicked))
        .disabled(!answerable)
        .help(answersOnClick ? "Answer \(label)" : (multiSelect ? "Pick or unpick \(label)" : "Pick \(label)"))
        .usageID(answersOnClick ? "answer-option" : "pick-option", label: "Answer a question from Scope")
    }

    @ViewBuilder
    private var plan: some View {
        if let text = request.plan {
            ScrollView {
                Text(LocalizedStringKey(text))
                    .font(.scopeBody)
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let file = request.planFilePath {
            detailLine(file, mono: true)
        }
    }

    @ViewBuilder
    private var elicitation: some View {
        if let message = request.message {
            Text(message)
                .font(.scopeBody)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !request.fields.isEmpty {
            detailLine("Fields: " + request.fields.joined(separator: ", "))
        }
        if let url = request.url {
            detailLine(url, mono: true)
        }
    }

    private func code(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.scopeValue)
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
        .background(Surface.field, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Surface.stroke))
    }

    private func detailLine(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .scopeValue : .scopeCaption)
            .foregroundStyle(Ink.secondary)
            .textSelection(.enabled)
            .lineLimit(3)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Text(hint)
                .font(.scopeCaption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if request.kind == .permission, answerable {
                Button("Deny") { answer(.deny) }
                    .buttonStyle(.scopeSecondary)
                    .help("Deny — like Esc in the terminal's dialog")
                    .usageID("deny", label: "Deny a permission from Scope")
                Button("Allow") { answer(.allow) }
                    .buttonStyle(.scopePrimary)
                    .help("Allow once — like 1. Yes in the terminal's dialog")
                    .usageID("allow", label: "Allow a permission from Scope")
            } else if request.kind == .question, answerable, !answersOnClick {
                Button("Submit Answers") { answer(.choose(choices)) }
                    .buttonStyle(.scopePrimary)
                    .disabled(!complete)
                    .help(complete ? "Type these answers into the terminal" : "Pick an option for every question")
                    .usageID("submit", label: "Submit answers from Scope")
            }
        }
    }

    private var hint: String {
        switch request.kind {
        case .permission where answerable: "Or answer in the terminal."
        case .permission: "Answer in the terminal: Scope cannot tell this dialog from another."
        case .question where answersOnClick: "Click an option to answer, or answer in the terminal."
        case .question: "Pick, then submit — or answer in the terminal."
        case .plan: "Approve or change the plan in the terminal: its options depend on your settings."
        case .elicitation: "Fill the form in the terminal."
        }
    }

    private var choices: [[Int]] {
        request.questions.indices.map { (picked[$0] ?? []).sorted() }
    }

    private var complete: Bool {
        request.questions.indices.allSatisfy { !(picked[$0] ?? []).isEmpty }
    }

    private func answer(_ answer: ClaudeDialogAnswer) {
        switch model.answerPendingRequest(session.id, requestID: request.id, with: answer) {
        case .success: refusal = nil
        case .failure(let why): refusal = "Not sent: \(why.description)."
        }
    }
}

/// An option of a question: a quiet row that washes on hover and holds its tint once picked.
private struct OptionButtonStyle: ButtonStyle {
    var picked: Bool

    func makeBody(configuration: Configuration) -> some View {
        Wash(configuration: configuration, picked: picked)
    }

    private struct Wash: View {
        let configuration: Configuration
        let picked: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Surface.stroke))
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Fill.pressed }
            if picked { return Fill.selectedTint }
            return hovering ? Fill.hover : Fill.quiet
        }
    }
}
