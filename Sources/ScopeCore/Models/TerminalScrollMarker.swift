import Foundation

/// Where the terminal's scroll marker sits: a knob whose length says how much of the history is on screen and
/// whose place says which part of it. Pure, so the arithmetic is tested rather than eyeballed.
public enum TerminalScrollMarker {
    /// Shortest knob drawn, in points: ten thousand lines of history would otherwise leave a sliver nobody sees.
    public static let minimumLength: Double = 24

    /// The knob along a track of `trackLength` points, measured from the top of the track.
    /// - Parameters:
    ///   - position: 0 with the oldest line at the top of the screen, 1 with the newest (SwiftTerm's
    ///     `scrollPosition`).
    ///   - proportion: visible rows over all lines (SwiftTerm's `scrollThumbsize`).
    ///   - canScroll: `false` in the alternate screen and while everything fits.
    /// - Returns: `nil` when there is nothing to scroll: no marker at all, not an empty track.
    public static func knob(trackLength: Double, position: Double, proportion: Double,
                            canScroll: Bool) -> (offset: Double, length: Double)? {
        guard canScroll, trackLength > 0, proportion > 0, proportion < 1 else { return nil }
        let length = min(trackLength, max(minimumLength, proportion * trackLength))
        let clamped = min(max(position, 0), 1)
        return (offset: clamped * (trackLength - length), length: length)
    }
}
