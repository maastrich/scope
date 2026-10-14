import Foundation

/// One two-finger horizontal swipe that pages between neighbours — the scopes in the sidebar — followed from the
/// first event to the release. Pure arithmetic: the app feeds it the trackpad's deltas and draws `offset`.
///
/// The gesture behaves like paging in the system's own apps:
/// - **Axis lock.** Nothing is decided until the fingers have moved `Tuning.lockDistance`; the dominant axis then
///   holds for the rest of the gesture. A vertical start stays a scroll of the list, however it curves afterwards.
/// - **Follows the fingers.** `offset` moves one to one with them, up to a full page.
/// - **Rubber band.** Towards a side with no neighbour, `offset` resists more the further it is pulled. The scopes
///   form a ring, so in the sidebar that is only ever a lone scope.
/// - **Release decides.** A page turns when it is dragged past `Tuning.commitFraction` of its width, or flicked
///   faster than `Tuning.flickVelocity` — and never against the flick.
public struct PageSwipe: Sendable {
    public struct Tuning: Sendable {
        /// Points of travel before the axis is chosen.
        public var lockDistance: Double = 8
        /// How much more horizontal than vertical the start must be to count as a swipe.
        public var horizontalBias: Double = 1.5
        /// Fraction of the page width that turns the page when released slowly.
        public var commitFraction: Double = 0.35
        /// Points per second that turn the page whatever the distance.
        public var flickVelocity: Double = 500
        /// Points a flick needs to have travelled, so a twitch while resting the fingers turns nothing.
        public var flickMinimumTravel: Double = 12
        /// The rubber band's stiffness, as UIScrollView's: 0 does not move, 1 follows the fingers.
        public var rubberBand: Double = 0.55
        /// Movement older than this at release is not part of the flick: fingers that stopped have no velocity.
        public var velocityWindow: TimeInterval = 0.08

        public init() {}
    }

    public enum Axis: Sendable, Equatable {
        case undecided, horizontal, vertical
    }

    public enum Outcome: Sendable, Equatable {
        /// Turn the page: +1 to the next neighbour (fingers moved left), −1 to the previous one.
        case turn(Int)
        case stay
    }

    public let width: Double
    public let hasPrevious: Bool
    public let hasNext: Bool
    public let tuning: Tuning

    public private(set) var axis: Axis = .undecided
    /// The fingers' horizontal travel since the gesture began, positive to the right.
    public private(set) var travel: Double = 0
    private var pendingX: Double = 0
    private var pendingY: Double = 0
    private var samples: [(time: TimeInterval, dx: Double)] = []

    public init(width: Double, hasPrevious: Bool, hasNext: Bool, tuning: Tuning = Tuning()) {
        self.width = max(width, 1)
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        self.tuning = tuning
    }

    /// Feeds one movement of the fingers, positive to the right and up, and returns the axis it now belongs to.
    @discardableResult
    public mutating func move(dx: Double, dy: Double, at time: TimeInterval) -> Axis {
        switch axis {
        case .vertical:
            break
        case .horizontal:
            travel += dx
            samples.append((time, dx))
            samples.removeAll { time - $0.time > tuning.velocityWindow }
        case .undecided:
            pendingX += dx
            pendingY += dy
            guard hypot(pendingX, pendingY) >= tuning.lockDistance else { break }
            if abs(pendingX) > abs(pendingY) * tuning.horizontalBias {
                axis = .horizontal
                // The points spent deciding are part of the swipe: dropping them would make the page jump behind
                // the fingers on the first frame it moves.
                travel = pendingX
                samples = [(time, pendingX)]
            } else {
                axis = .vertical
            }
        }
        return axis
    }

    /// Where the page sits, positive to the right: the fingers' travel, capped at a page, rubber-banded towards a
    /// side with nothing on it.
    public var offset: Double {
        guard axis == .horizontal else { return 0 }
        // Fingers moving right reveal the previous neighbour on the left, and the other way round.
        let open = travel > 0 ? hasPrevious : hasNext
        let magnitude = abs(travel)
        let shown = open ? min(magnitude, width) : Self.rubberBand(magnitude, dimension: width, stiffness: tuning.rubberBand)
        return travel < 0 ? -shown : shown
    }

    /// The fingers' horizontal speed at `time`, in points per second, positive to the right.
    public func velocity(at time: TimeInterval) -> Double {
        let recent = samples.filter { time - $0.time <= tuning.velocityWindow }
        guard let first = recent.first else { return 0 }
        // Spread over the whole window, so one late event does not stand for a whole flick.
        let span = max(time - first.time, 1.0 / 120)
        return recent.reduce(0) { $0 + $1.dx } / span
    }

    /// What the release means: turn a page, or settle back.
    public func end(at time: TimeInterval) -> Outcome {
        guard axis == .horizontal else { return .stay }
        let velocity = velocity(at: time)
        let direction: Double
        if abs(velocity) >= tuning.flickVelocity, abs(travel) >= tuning.flickMinimumTravel {
            // A flick back towards where the page came from cancels it, however far it had been dragged.
            guard velocity.sign == travel.sign else { return .stay }
            direction = velocity
        } else if abs(travel) >= width * tuning.commitFraction {
            direction = travel
        } else {
            return .stay
        }
        if direction < 0 { return hasNext ? .turn(1) : .stay }
        return hasPrevious ? .turn(-1) : .stay
    }

    /// UIScrollView's rubber band: close to one to one for a short pull, never reaching `dimension`.
    public static func rubberBand(_ distance: Double, dimension: Double, stiffness: Double) -> Double {
        (1 - 1 / (distance * stiffness / dimension + 1)) * dimension
    }
}
