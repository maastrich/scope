import SwiftUI
import ScopeCore

/// Toolbar badge showing the unread problem count, with a popover listing every `ProblemCenter` entry
/// (title, copyable detail, age, actions). Opening the popover marks everything read.
struct ProblemPopover: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Problems", systemImage: symbolName)
                .overlay(alignment: .topTrailing) {
                    if model.problems.unreadCount > 0 {
                        Text(model.problems.unreadCount, format: .number)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 14, minHeight: 14)
                            .background(Color(nsColor: .systemRed), in: Capsule())
                            .offset(x: 8, y: -6)
                    }
                }
        }
        .help(model.problems.problems.isEmpty ? "No problems" : "\(model.problems.problems.count) problems")
        .accessibilityLabel(model.problems.unreadCount > 0 ? "Problems, \(model.problems.unreadCount) unread" : "Problems")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProblemList()
                .frame(width: 380)
                .frame(minHeight: 120, maxHeight: 480)
                .onAppear { model.problems.markAllRead() }
        }
    }

    private var symbolName: String {
        if model.problems.problems.contains(where: { $0.severity == .error }) {
            return "exclamationmark.octagon"
        }
        return "exclamationmark.triangle"
    }
}

/// The popover body: newest problem first.
private struct ProblemList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.problems.problems.isEmpty {
            ContentUnavailableView("No problems", systemImage: "checkmark.circle",
                                   description: Text("Launch failures, scan errors and unreadable files show up here."))
                .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.problems.problems.reversed()) { problem in
                        ProblemRowView(problem: problem)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct ProblemRowView: View {
    @Environment(AppModel.self) private var model
    let problem: Problem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: severitySymbol)
                    .foregroundStyle(severityColor)
                Text(problem.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(problem.createdAt, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    model.problems.dismiss(problem.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss \(problem.title)")
            }
            if let detail = problem.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !problem.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(problem.actions) { action in
                        Button(action.title) {
                            model.problems.onAction?(action)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var severitySymbol: String {
        switch problem.severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.octagon"
        }
    }

    private var severityColor: Color {
        switch problem.severity {
        case .info: Color(nsColor: .systemBlue)
        case .warning: Color("WarningText")
        case .error: Color(nsColor: .systemRed)
        }
    }
}
