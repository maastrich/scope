import SwiftUI
import ScopeCore

/// `localhost:41003 ↗` for each port of the task's block something listens on: the dev servers the task is running.
/// A click opens the browser on it. Nothing is drawn when no port is taken.
struct TaskPortChips: View {
    @Environment(AppModel.self) private var model
    let task: TaskState
    var compact = false

    var body: some View {
        if !task.listeningPorts.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(task.listeningPorts, id: \.self) { port in
                    Button {
                        model.openPort(port)
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
                    .help("Open http://localhost:\(String(port)) — a server of this task listens there")
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
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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
