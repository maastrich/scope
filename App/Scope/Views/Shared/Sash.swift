import AppKit
import SwiftUI

/// The one grip every resizable boundary in the window uses: the columns in `RootView`, the lists of the inspector in
/// `CollapsibleSection`. A 1 pt line is what the eye sees; the pointer gets a 10 pt band centred on it, the resize
/// cursor over the whole band, a drag that moves the boundary and a double-click that puts it back where a fresh
/// install starts.
///
/// The band is drawn as an overlay so it never takes room in the layout — the line stays flush between its two
/// neighbours and the grip reaches 4.5 pt into each of them. The drag reports the translation from its start, never an
/// increment: the owner keeps the value at the start and clamps, so a drag past a bound does not drift when it comes back.
struct Sash: View {
    enum Axis { case horizontal, vertical }

    /// `.vertical` runs top to bottom (between columns); `.horizontal` left to right (between stacked lists).
    let axis: Axis
    /// Whether the 1 pt line is drawn: the column sashes own their hairline, a section sash sits on a rule the header
    /// already draws.
    var drawsLine = true
    var began: () -> Void = {}
    /// Points along the cross axis since the drag began: `width` for a vertical sash, `height` for a horizontal one.
    var moved: (Double) -> Void
    var ended: () -> Void = {}
    /// The double-click: back to the default for this dimension.
    var reset: () -> Void
    @State private var dragging = false

    static let hitThickness: Double = 10

    var body: some View {
        line
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? Self.hitThickness : nil,
                           height: axis == .horizontal ? Self.hitThickness : nil)
                    .contentShape(Rectangle())
                    .cursor(axis == .vertical ? .resizeLeftRight : .resizeUpDown)
                    .onTapGesture(count: 2, perform: reset)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !dragging {
                                    dragging = true
                                    began()
                                }
                                moved(Double(axis == .vertical ? value.translation.width : value.translation.height))
                            }
                            .onEnded { _ in
                                dragging = false
                                ended()
                            }
                    )
            }
    }

    @ViewBuilder
    private var line: some View {
        if drawsLine {
            Rectangle()
                .fill(Surface.stroke)
                .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
                .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
        } else {
            Color.clear
                .frame(width: axis == .vertical ? 0 : nil, height: axis == .horizontal ? 0 : nil)
                .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
        }
    }
}
