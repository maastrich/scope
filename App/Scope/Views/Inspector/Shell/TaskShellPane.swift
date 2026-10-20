import AppKit
import SwiftUI
import ScopeCore
import ScopeDrivers

/// The task's shell pane in the reading column (spec §7): a band naming the task's sandbox with one tab per
/// shell, the terminal of the shown tab, and a footer saying what the shell got. A scratch terminal of the
/// task, beside the agent's thread — never a thread itself.
struct TaskShellPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var leading: AnyView?
    var trailing: AnyView?

    var body: some View {
        let preferences = model.config.preferences
        // Push the preferences before the host reads them; the ground below the insets uses the same palette.
        TerminalAppearance.configure(preferences)
        return VStack(spacing: 0) {
            band
            Divider()
            ZStack {
                Color(nsColor: TerminalAppearance.background)
                    .id(preferences.terminalAppearance)
                if let session = model.currentTaskShell {
                    TaskShellHost(session: session, fontSize: preferences.terminalFontSize,
                                  appearance: preferences.terminalAppearance, cursorStyle: preferences.terminalCursorStyle)
                        .id(session.id)
                        .focusable(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.currentTaskShells.map(\.id))
    }

    // MARK: Band

    private var band: some View {
        HStack(spacing: 8) {
            if let leading { leading }
            Image(systemName: "terminal")
                .font(.scopeCaption)
                .foregroundStyle(Ink.secondary)
            Text("Shell")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Ink.primary)
            if let subject {
                Text("· \(subject)")
                    .font(.scopeCaption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            tabs
            Spacer(minLength: 4)
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

    /// `sandbox · scope`, or the task's name when its threads start at the task root.
    private var subject: String? {
        guard let task = model.currentTask, let scope = model.scope(task.scopeID) else { return nil }
        if let sandbox = task.record.sandbox(containing: task.record.threadCwd.path) {
            return sandbox.sandboxLabel(scopeName: scope.name)
        }
        return task.name
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            TabStrip(selection: selection, items: model.currentTaskShells.map { (value: $0.id, title: $0.title) })
            if let shell = model.currentTaskShell {
                Button {
                    model.closeTaskShell(shell.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .help("Close this shell")
                .accessibilityLabel("Close this shell")
                .usageID("close-tab", label: "Close a shell tab")
            }
            Button {
                if let task = model.currentTask { model.openTaskShell(in: task) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .help("New shell")
            .accessibilityLabel("New shell")
            .usageID("new-tab", label: "New shell tab")
        }
        .fixedSize()
    }

    private var selection: Binding<TaskShellID> {
        Binding(
            get: { model.currentTaskShell?.id ?? TaskShellID(rawValue: "") },
            set: { model.selectTaskShell($0) }
        )
    }

    // MARK: Footer

    private var footer: some View {
        let environment = model.currentTaskShell?.environment ?? [:]
        return HStack(spacing: 10) {
            Text(TaskShell.injectedSummary(environment))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(TaskShell.injectedVariables(environment).joined(separator: "\n"))
            Spacer(minLength: 4)
            Text("⌃` toggles · ⎋ closes")
                .fixedSize()
                .help("⌃` shows and hides the pane; Esc closes it when the keyboard is not in the shell")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Ink.tertiary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Surface.panel)
    }
}
