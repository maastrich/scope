import SwiftUI
import ScopeCore

/// One tab per thread of the current scope: state dot, `Driver · scope` label, `⌘n` hint for the first
/// nine, a close button on the active / hovered tab, and a trailing "+" (default driver; the menu lists
/// every driver).
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    let scope: ScopeState
    let threads: [ThreadSession]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(threads.enumerated()), id: \.element.id) { index, session in
                        TabCell(session: session,
                                index: index,
                                isActive: model.selectedThreadID == session.id)
                        Divider()
                            .frame(height: 30)
                    }
                }
            }
            Spacer(minLength: 0)
            newThreadButton
        }
        .frame(height: 30)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var newThreadButton: some View {
        Menu {
            ForEach(model.drivers.profiles) { profile in
                Button(profile.name) {
                    Task { _ = await model.newThread(in: scope.id, driverID: profile.id) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        } primaryAction: {
            Task { _ = await model.newThread(in: scope.id) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("New Thread (⌘T) — long-press or right-click to choose a driver")
    }
}

private struct TabCell: View {
    @Environment(AppModel.self) private var model
    let session: ThreadSession
    let index: Int
    let isActive: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            StateDot(state: session.displayState, size: 7)
            Text(session.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { _ = await model.close(session.id, force: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovered ? 1 : 0)
            .help("Close Thread (⌘W)")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background {
            if isActive {
                Color(nsColor: .controlBackgroundColor)
            } else if isHovered {
                Color.primary.opacity(0.04)
            }
        }
        .overlay(alignment: .top) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = .thread(session.id)
            model.selectedThreadID = session.id
        }
        .onHover { isHovered = $0 }
        .help(session.record.cwd)
    }
}
