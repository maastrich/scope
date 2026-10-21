import SwiftUI
import ScopeCore

/// Toasts for the failures of something the user just asked for (*Add repo…*, *Add Branch…*), under the undo toasts.
/// Each one: the title, the first line of the detail — the plain-words reason when there is one — Details (the
/// whole output, selectable) and dismiss. They stay until dismissed; the problem stays in the toolbar popover.
struct ProblemToastStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.problems.toasts) { problem in
                ProblemToast(problem: problem)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.problems.toasts.map(\.id))
        .usageArea("problem-toast")
    }
}

private struct ProblemToast: View {
    @Environment(AppModel.self) private var model
    let problem: Problem
    @State private var showsDetails = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if problem.detail != nil {
                Button("Details") {
                    showsDetails.toggle()
                }
                .buttonStyle(.scopeSecondary)
                .usageID("problem-toast.details", label: "Details (problem toast)")
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    ScrollView {
                        Text(problem.detail ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(width: 480)
                    .frame(maxHeight: 320)
                }
            }
            Button {
                model.problems.dismissToast(problem.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss (it stays in the problems popover)")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Surface.elevated, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Surface.stroke))
        .shadow(color: .black.opacity(0.14), radius: 4, y: 1)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
    }

    /// The first line of the detail: `geo: git-lfs is installed (…) but not on Scope's PATH…`.
    private var summary: String? {
        guard let line = problem.detail?.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        return String(line)
    }
}
