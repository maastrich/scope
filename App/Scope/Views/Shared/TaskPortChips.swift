import SwiftUI
import ScopeCore

/// `localhost:41003 ↗` for each port of the task's block something listens on: the dev servers the task is running.
/// A click opens it in the task's Browser pane (the system browser with ⌥, or as the preference says). Nothing is
/// drawn when no port is taken.
struct TaskPortChips: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    var compact = false

    var body: some View {
        if !task.listeningPorts.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(task.listeningPorts, id: \.self) { port in
                    Button {
                        model.openPort(port, of: task)
                    } label: {
                        HStack(spacing: 3) {
                            Text("localhost:\(String(port))")
                                .font(.system(size: compact ? 10.5 : 11, design: .monospaced))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: compact ? 8 : 9, weight: .semibold))
                        }
                        .padding(.horizontal, 6)
                        .frame(height: compact ? 17 : 19)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                    .help("Open http://localhost:\(String(port)) in the Browser pane — a server of this task listens there; ⌥-click for the system browser")
                    .accessibilityLabel("Open localhost port \(String(port))")
                    .usageID("task-port", label: "Open a task's port")
                }
            }
        }
    }
}

/// Children laid out left to right, wrapping to the next line when the width runs out.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    /// Each row centred in the width rather than flush left: for a row of buttons under a centred heading.
    var centered = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Rows first, then each one placed: a centred row needs its width before its first child goes down.
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for row in rows where !row.isEmpty {
            let width = row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(row.count - 1)
            var x = centered ? bounds.minX + max(0, (bounds.width - width) / 2) : bounds.minX
            let rowHeight = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}

/// `1.2 GB on disk`, from the task's last measurement; nothing until one was made.
struct TaskDiskCaption: View {
    let task: TaskState

    var body: some View {
        if let usage = task.diskUsage {
            Text("\(SandboxSize.text(usage.bytes)) on disk")
                .help("What the task's sandboxes take, measured \(usage.measuredAt.formatted(.relative(presentation: .named)))")
                .accessibilityLabel("\(SandboxSize.text(usage.bytes)) on disk")
        }
    }
}
