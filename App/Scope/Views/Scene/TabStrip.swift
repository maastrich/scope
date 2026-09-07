import SwiftUI
import ScopeCore

/// One tab per thread of the current scope (120…240 pt each): state dot, numbered `Driver · scope` label,
/// `⌘n` hint for the first nine, a close button on the active / hovered tab. The strip scrolls to the
/// selected tab; when the tabs overflow, a "Show all tabs" menu lists them. A fixed trailing cell holds
/// the `+` (default driver; the menu lists every driver) after a divider.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: ScopeState
    let threads: [ThreadSession]
    @State private var contentWidth: CGFloat = 0
    @State private var stripWidth: CGFloat = 0

    private var overflows: Bool { contentWidth > stripWidth + 1 }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(threads.enumerated()), id: \.element.id) { index, session in
                            TabCell(session: session,
                                    index: index,
                                    isActive: model.selectedThreadID == session.id)
                                .id(session.id)
                            Divider()
                                .frame(height: 30)
                        }
                    }
                    .background(WidthReader(width: $contentWidth))
                }
                .background(WidthReader(width: $stripWidth))
                .onChange(of: model.selectedThreadID, initial: true) { _, id in
                    guard let id else { return }
                    if reduceMotion {
                        proxy.scrollTo(id, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Divider()
                .frame(height: 30)
            if overflows {
                overflowMenu
            }
            newThreadButton
        }
        .frame(height: 30)
        .background(Color("PanelBackground"))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(threads) { session in
                Button {
                    model.selection = .thread(session.id)
                    model.selectedThreadID = session.id
                } label: {
                    if model.selectedThreadID == session.id {
                        Label(model.displayTitle(for: session), systemImage: "checkmark")
                    } else {
                        Text(model.displayTitle(for: session))
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Show all tabs")
        .accessibilityLabel("Show all tabs")
    }

    private var newThreadButton: some View {
        Menu {
            ForEach(model.drivers.profiles) { profile in
                Button(profile.name) {
                    Task { await model.newThreadInCurrentContext(driverID: profile.id) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        } primaryAction: {
            Task { await model.newThreadInCurrentContext() }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("New Thread \(model.newThreadTargetDescription ?? "in \(scope.name)") (⌘T) — long-press or right-click to choose a driver")
        .accessibilityLabel("New Thread \(model.newThreadTargetDescription ?? "in \(scope.name)")")
    }
}

/// Reports the width of the view it backs.
private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width, initial: true) { _, value in width = value }
        }
    }
}

private struct TabCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ThreadSession
    let index: Int
    let isActive: Bool
    @State private var isHovered = false

    private var isExited: Bool { !session.isAlive }

    var body: some View {
        let title = model.displayTitle(for: session)
        let secondary = model.secondaryTitle(for: session)
        HStack(spacing: 7) {
            StateDot(state: session.displayState, size: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: secondary == nil ? 12 : 11.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive && !isExited ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovered ? 1 : 0)
            .help("Close Thread (⌘W)")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, maxWidth: 240)
        .frame(height: 30)
        .opacity(isExited ? 0.6 : 1)
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
        .onHover { hovering in
            if reduceMotion {
                isHovered = hovering
            } else {
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
        }
        .help(tooltip(title: title, secondary: secondary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isExited ? "\(title), exited" : title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func tooltip(title: String, secondary: String?) -> String {
        var lines = [title]
        if let secondary { lines.append(secondary) }
        lines.append(session.record.cwd)
        return lines.joined(separator: "\n")
    }
}
