import SwiftUI
import ScopeCore
import ScopeDrivers

/// Non-modal banner shown over the terminal while the process is not alive:
/// not started since the last quit, launching (shell probe / driver start), exited, or launch failure.
/// Actions: Relaunch (⌘R — resumes the previous driver session when there is one), Start Fresh (only then),
/// Close (⌘W), Show details.
struct ThreadBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let session: ThreadSession
    @State private var showsDetails = false

    /// The banner sits on the terminal ground, so it follows the terminal palette rather than the window.
    private var terminalIsDark: Bool {
        model.config.preferences.terminalAppearance == .alwaysDark || colorScheme == .dark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(showsDetails ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                actions
            }
            if showsDetails, let details {
                Text(details)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        .environment(\.colorScheme, terminalIsDark ? .dark : .light)
        .frame(maxWidth: 720)
    }

    // MARK: Content

    private var isProbingShell: Bool {
        if case .launching = session.phase, model.shellStatus == .probing { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch session.phase {
        case .launching:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.octagon")
                .foregroundStyle(Color(nsColor: .systemRed))
        case .exited(let status) where !status.isClean:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color("WarningText"))
        default:
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch session.phase {
        case .notStarted:
            return "Not running since the last quit"
        case .launching:
            return isProbingShell ? "Resolving your shell environment…" : "Starting \(session.profile.name)…"
        case .alive:
            return session.profile.name
        case .exited(let status):
            if status.isExecFailure {
                return "The command could not be started (exit 127)"
            }
            return "Exited · \(status.summary)"
        case .failed:
            return session.lastError?.title ?? "Launch failed"
        }
    }

    private var subtitle: String? {
        if let skip = model.autoRelaunchBlocks[session.id] {
            return "Not relaunched when Scope opened: \(skip.reason)."
        }
        switch session.phase {
        case .notStarted:
            return session.canResume
                ? "Relaunch picks the previous \(session.profile.name) session back up; Start Fresh opens a new one."
                : "Relaunch starts \(session.profile.name) in \(session.record.cwd)."
        case .launching:
            return isProbingShell
                ? "Running your login shell once to read PATH and the other variables agents need."
                : nil
        case .alive:
            return nil
        case .exited(let status):
            if status.isExecFailure {
                return "Check the `command` of the \(session.profile.id) driver profile."
            }
            return status.at.formatted(.relative(presentation: .named))
        case .failed(let message):
            return session.lastError?.detail ?? message
        }
    }

    private var details: String? {
        switch session.phase {
        case .failed(let message):
            return session.lastError.map { "\($0.title)\n\($0.detail)" } ?? message
        case .exited(let status):
            var lines = [status.summary]
            if let launchedAt = session.record.lastLaunchedAt {
                lines.append("launched \(launchedAt.formatted(date: .abbreviated, time: .standard))")
            }
            lines.append("launches: \(session.record.launchCount)")
            lines.append("cwd: \(session.record.cwd)")
            return lines.joined(separator: "\n")
        default:
            return nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if case .launching = session.phase {
                // Nothing to do but wait; the launcher falls back on its own if the probe times out.
            } else {
                Button("Relaunch") {
                    Task { await model.relaunch(session.id) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(session.canResume ? "Relaunch (⌘R) — resumes the previous session" : "Relaunch (⌘R)")
                if session.canResume {
                    Button("Start Fresh") {
                        Task { await model.startFresh(session.id) }
                    }
                    .help("A new \(session.profile.name) session instead of the previous one")
                }
                if details != nil {
                    Button(showsDetails ? "Hide details" : "Show details") {
                        showsDetails.toggle()
                    }
                }
                Button("Close") {
                    Task { _ = await model.close(session.id, force: false) }
                }
                .help("Close Thread (⌘W)")
            }
        }
        .controlSize(.small)
    }
}
