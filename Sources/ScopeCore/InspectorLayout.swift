import Foundation

/// One collapsible section of the inspector column, top to bottom.
///
/// The inspector used to be three tabs, Base holding a second row of three more: two rows of tabs stood between the
/// window and the first file, and every tab hid what it held. The sections are always all there, one header each, so
/// what exists is visible at a glance; a closed one costs one line and still says the essential in its header.
public enum InspectorSection: String, Codable, Sendable, CaseIterable, Hashable {
    case task, delta, pullRequest, base, files, search, history

    public var title: String {
        switch self {
        case .task: "Task"
        case .delta: "Delta"
        case .pullRequest: "Pull Request"
        case .base: "Base"
        case .files: "Files"
        case .search: "Search"
        case .history: "History"
        }
    }

    /// Whether the section has nothing to show without a task; it stays on screen, dimmed, so the column keeps its shape.
    public var needsTask: Bool {
        switch self {
        case .task, .delta, .pullRequest: true
        case .base, .files, .search, .history: false
        }
    }

    /// Whether the section is a list that grows into whatever height it is given (and shares it with the other such
    /// sections), rather than a block that takes its own height.
    public var fills: Bool {
        switch self {
        case .delta, .files, .search, .history: true
        case .task, .pullRequest, .base: false
        }
    }
}

/// Which sections are open, kept per scope (`ScopePlace`).
///
/// Two sets, because a task and the lack of one call for different panels: with a task the changes are the subject,
/// without one the base checkout is. Opening Files on a repo row must not open it on the next task, and the reverse.
public struct InspectorSections: Codable, Sendable, Equatable {
    public var withTask: Set<InspectorSection>
    public var withoutTask: Set<InspectorSection>

    /// At rest very little is open: the changes of a task, the base checkout of anything else. Files never opens by
    /// itself.
    public static let defaults = InspectorSections(withTask: [.delta], withoutTask: [.base])

    public init(withTask: Set<InspectorSection>, withoutTask: Set<InspectorSection>) {
        self.withTask = withTask
        self.withoutTask = withoutTask.filter { !$0.needsTask }
    }

    public func open(hasTask: Bool) -> Set<InspectorSection> {
        hasTask ? withTask : withoutTask
    }

    public func isOpen(_ section: InspectorSection, hasTask: Bool) -> Bool {
        (hasTask || !section.needsTask) && open(hasTask: hasTask).contains(section)
    }

    /// A section that needs a task cannot be opened without one: the request is dropped, not kept for later.
    public mutating func setOpen(_ section: InspectorSection, _ isOpen: Bool, hasTask: Bool) {
        guard hasTask || !section.needsTask else { return }
        if hasTask {
            if isOpen { withTask.insert(section) } else { withTask.remove(section) }
        } else {
            if isOpen { withoutTask.insert(section) } else { withoutTask.remove(section) }
        }
    }

    private enum CodingKeys: String, CodingKey { case withTask, withoutTask }

    // Lenient: a section this build does not know (renamed, removed) is dropped instead of failing the whole place.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func sections(_ key: CodingKeys) -> Set<InspectorSection>? {
            guard let raw = try? container.decodeIfPresent([String].self, forKey: key) else { return nil }
            return Set(raw.compactMap(InspectorSection.init(rawValue:)))
        }
        self.init(withTask: sections(.withTask) ?? Self.defaults.withTask,
                  withoutTask: sections(.withoutTask) ?? Self.defaults.withoutTask)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(withTask.map(\.rawValue).sorted(), forKey: .withTask)
        try container.encode(withoutTask.map(\.rawValue).sorted(), forKey: .withoutTask)
    }
}

/// How the column's height is shared out between the open sections, and how dragging the sash between two of them
/// moves it. Pure arithmetic in points, so it is tested here rather than eyeballed in the app.
public enum InspectorSectionLayout {
    /// One section as the layout sees it: whether it is open, whether it fills, and — for a block — the height its
    /// content asks for.
    public struct Item: Sendable, Equatable {
        public var section: InspectorSection
        public var isOpen: Bool
        public var natural: Double

        public init(section: InspectorSection, isOpen: Bool, natural: Double = 0) {
            self.section = section
            self.isOpen = isOpen
            self.natural = natural
        }
    }

    public static let headerHeight: Double = 22
    /// The least a list keeps: a few rows, so an open list never collapses into a header that looks closed.
    public static let minimumFill: Double = 72
    /// The least a block keeps when the column is short; under that it scrolls inside its own height.
    public static let minimumBlock: Double = 36

    /// The body height of every open section (closed ones are absent). Blocks get the height they ask for while it
    /// leaves each open list its minimum, and shrink in proportion when it does not; the lists share the rest by
    /// weight, never under their minimum. When even the minimums do not fit, the total exceeds `available` and the
    /// column scrolls.
    public static func bodyHeights(available: Double, items: [Item], weights: [InspectorSection: Double]) -> [InspectorSection: Double] {
        let open = items.filter(\.isOpen)
        let fills = open.filter(\.section.fills)
        let blocks = open.filter { !$0.section.fills }
        let room = max(0, available - Double(items.count) * headerHeight)
        var result: [InspectorSection: Double] = [:]

        let wanted = blocks.reduce(0) { $0 + max(0, $1.natural) }
        let blockRoom = max(0, room - Double(fills.count) * minimumFill)
        let scale = wanted > blockRoom && wanted > 0 ? blockRoom / wanted : 1
        var used = 0.0
        for block in blocks {
            let height = min(max(0, block.natural), max(max(0, block.natural) * scale, minimumBlock))
            result[block.section] = height
            used += height
        }

        guard !fills.isEmpty else { return result }
        let shares = fills.map { max(weights[$0.section] ?? 1, 0.0001) }
        let total = shares.reduce(0, +)
        let fillRoom = max(room - used, Double(fills.count) * minimumFill)
        // Proportional first, then any list pushed under its minimum takes it back from the others.
        var heights = shares.map { fillRoom * $0 / total }
        var deficit = 0.0
        for index in heights.indices where heights[index] < minimumFill {
            deficit += minimumFill - heights[index]
            heights[index] = minimumFill
        }
        while deficit > 0.0001 {
            let donors = heights.indices.filter { heights[$0] > minimumFill }
            guard !donors.isEmpty else { break }
            let slack = donors.reduce(0) { $0 + heights[$1] - minimumFill }
            let take = min(deficit, slack)
            for index in donors {
                heights[index] -= take * (heights[index] - minimumFill) / slack
            }
            deficit -= take
        }
        for (fill, height) in zip(fills, heights) { result[fill.section] = height }
        return result
    }

    /// The weights after dragging the sash between `upper` and `lower` by `delta` points (down is positive), from the
    /// list heights at the start of the drag. Both stay at least `minimumFill`; every other list keeps its height.
    /// Weights come back as heights, which `bodyHeights` reads as proportions.
    public static func resize(heights: [InspectorSection: Double], upper: InspectorSection, lower: InspectorSection,
                              by delta: Double) -> [InspectorSection: Double] {
        guard let top = heights[upper], let bottom = heights[lower] else { return heights }
        let pair = top + bottom
        guard pair >= 2 * minimumFill else { return heights }
        let newTop = min(max(top + delta, minimumFill), pair - minimumFill)
        var result = heights
        result[upper] = newTop
        result[lower] = pair - newTop
        return result
    }

}

/// Which folders of a file tree are open, by path. Empty — the root alone — whenever a tree is shown anew: an outline
/// that unrolls itself buries the one folder you were after.
public struct FileTreeExpansion: Sendable, Equatable {
    public private(set) var expanded: Set<String> = []

    public init() {}

    public func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    public mutating func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }

    /// Opens every folder above `path` and nothing else, so a file opened from Search shows where it lives.
    public mutating func reveal(_ path: String) {
        expanded.formUnion(Self.ancestors(of: path))
    }

    public mutating func collapseAll() {
        expanded = []
    }

    /// `a/b/c.swift` → `a`, `a/b`.
    public static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return [] }
        return (1..<parts.count).map { parts[0..<$0].joined(separator: "/") }
    }
}
