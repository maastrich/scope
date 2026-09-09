import SwiftUI
import ScopeCore

/// "2 threads waiting for you" — the count of threads blocked on the user, and ⌥⌘↩ to jump to the next one.
///
/// The per-row marks (square dot, bar, the word *needs you*) only help for a row that is on screen; this is what
/// catches a thread waiting further down a long list, or inside a collapsed task. Where it lives —
/// `Preferences.attentionCounter` — is a matter of taste: a banner in the sidebar, a button in the toolbar, or
/// nowhere.
struct AttentionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.waitingThreadsInCurrentScope
        if !waiting.isEmpty {
            Button {
                model.revealNextWaitingThread()
            } label: {
                HStack(spacing: 6) {
                    StateDot(state: .waiting(reason: .input))
                    Text(waiting.count == 1 ? "1 thread waiting for you" : "\(waiting.count) threads waiting for you")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color("WarningText"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text("⌥⌘↩")
                        .font(.system(size: 10))
                        .foregroundStyle(Color("WarningText").opacity(0.6))
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .background(ThreadStateStyle.waiting.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(EdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10))
            .help("Go to the next thread waiting for you (⌥⌘↩)")
            .accessibilityLabel("\(waiting.count) threads waiting for you. Go to the next one")
        }
    }
}

/// The toolbar form of the same counter: every scope, not just the one the sidebar shows, so a thread blocked in a
/// scope you are not looking at still reaches you.
struct AttentionToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.waitingThreads.count
        if count > 0 {
            Button {
                model.revealNextWaitingThread()
            } label: {
                HStack(spacing: 5) {
                    StateDot(state: .waiting(reason: .input), size: 7)
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color("WarningText"))
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(ThreadStateStyle.waiting.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("\(count) waiting for you — go to the next (⌥⌘↩)")
            .accessibilityLabel("\(count) threads waiting for you. Go to the next one")
        }
    }
}
