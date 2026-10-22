import Foundation

/// A link of the Graph view: `from` depends on `to`. Cards say it from either end — `depends_on` on the dependent,
/// `consumed_by` on the dependency — so one link may be stated twice, or once from each side.
public struct GraphEdge: Sendable, Hashable, Comparable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    public static func < (lhs: GraphEdge, rhs: GraphEdge) -> Bool {
        (lhs.from, lhs.to) < (rhs.from, rhs.to)
    }

    /// Every link the cards state between repos of the graph, each once, sorted. A relation to a repo the graph
    /// does not have, or to the card itself, is dropped.
    public static func build(_ repos: [String: RepoCard]) -> [GraphEdge] {
        var edges = Set<GraphEdge>()
        for (key, card) in repos {
            for relation in card.related where relation.repo != key && repos[relation.repo] != nil {
                switch relation.kind {
                case .dependsOn: edges.insert(GraphEdge(from: key, to: relation.repo))
                case .consumedBy: edges.insert(GraphEdge(from: relation.repo, to: key))
                }
            }
        }
        return edges.sorted()
    }

    /// The repos linked to `key`, both ways.
    public static func neighbours(of key: String, in edges: [GraphEdge]) -> Set<String> {
        var result = Set<String>()
        for edge in edges {
            if edge.from == key { result.insert(edge.to) }
            if edge.to == key { result.insert(edge.from) }
        }
        return result
    }
}

/// Where the Graph view draws each repo: a layered drawing, dependents above what they depend on.
///
/// Layered rather than force-directed: the relations are dependencies, which have a direction a reader follows top
/// to bottom, and a layered drawing is the same every time for the same graph without a seed to keep — adding a
/// repo moves its own layer, not the whole picture. Repos without any link are not placed: the view lists them
/// apart, where a force layout would scatter them through the drawing.
public struct GraphLayout: Sendable, Equatable {
    /// Grid position of each linked repo: `column` within its row, `row` from the top. Rows are centred: `column`
    /// may be fractional.
    public struct Slot: Sendable, Equatable {
        public var column: Double
        public var row: Int
    }

    public var slots: [String: Slot]
    /// Repos no link touches, sorted.
    public var isolated: [String]
    /// The widest row, in columns.
    public var columns: Int
    public var rows: Int

    public init(slots: [String: Slot] = [:], isolated: [String] = [], columns: Int = 0, rows: Int = 0) {
        self.slots = slots
        self.isolated = isolated
        self.columns = columns
        self.rows = rows
    }

    /// - Parameters:
    ///   - keys: every repo of the graph.
    ///   - edges: `GraphEdge.build`.
    ///   - maxPerRow: a layer wider than this wraps onto several rows, so thirty repos depending on one do not
    ///     make a drawing thirty nodes wide.
    public static func layered(keys: [String], edges: [GraphEdge], maxPerRow: Int = 8) -> GraphLayout {
        let all = Set(keys)
        let edges = Array(Set(edges.filter { all.contains($0.from) && all.contains($0.to) && $0.from != $0.to })).sorted()
        let linked = Set(edges.flatMap { [$0.from, $0.to] })
        let nodes = linked.sorted()
        let isolated = all.subtracting(linked).sorted()
        guard !nodes.isEmpty else { return GraphLayout(slots: [:], isolated: isolated, columns: 0, rows: 0) }

        let acyclic = breakCycles(nodes: nodes, edges: edges)
        let layerOf = sinkSources(longestPathLayers(nodes: nodes, edges: acyclic), edges: acyclic)
        let layerCount = (layerOf.values.max() ?? 0) + 1
        var layers = Array(repeating: [String](), count: layerCount)
        // Seeded by component, then key: the components stay side by side before the sweeps refine the order.
        let component = components(nodes: nodes, edges: edges)
        for node in nodes.sorted(by: { (component[$0]!, $0) < (component[$1]!, $1) }) {
            layers[layerOf[node]!].append(node)
        }
        layers = orderBySweeps(layers, edges: acyclic)

        // Wrap wide layers, then centre every row on the widest.
        var rows: [[String]] = []
        for layer in layers {
            stride(from: 0, to: layer.count, by: max(1, maxPerRow)).forEach { start in
                rows.append(Array(layer[start..<min(layer.count, start + maxPerRow)]))
            }
        }
        let columns = rows.map(\.count).max() ?? 0
        var slots: [String: Slot] = [:]
        for (rowIndex, row) in rows.enumerated() {
            let offset = Double(columns - row.count) / 2
            for (index, node) in row.enumerated() {
                slots[node] = Slot(column: offset + Double(index), row: rowIndex)
            }
        }
        return GraphLayout(slots: slots, isolated: isolated, columns: columns, rows: rows.count)
    }

    /// The edges with every cycle broken: a depth-first walk in key order reverses each edge back to a node still
    /// on its path. Deterministic, and only used to rank: the view still draws the edges as stated.
    static func breakCycles(nodes: [String], edges: [GraphEdge]) -> [GraphEdge] {
        var outgoing: [String: [String]] = [:]
        for edge in edges { outgoing[edge.from, default: []].append(edge.to) }
        var state: [String: Int] = [:]   // 1 = on the current path, 2 = done
        var reversed = Set<GraphEdge>()
        func visit(_ node: String) {
            state[node] = 1
            for next in (outgoing[node] ?? []).sorted() {
                switch state[next] {
                case 1: reversed.insert(GraphEdge(from: node, to: next))
                case nil: visit(next)
                default: break
                }
            }
            state[node] = 2
        }
        for node in nodes where state[node] == nil { visit(node) }
        return edges.map { reversed.contains($0) ? GraphEdge(from: $0.to, to: $0.from) : $0 }
    }

    /// Layer of each node: 0 for a node nothing depends on, else one below its lowest dependent.
    static func longestPathLayers(nodes: [String], edges: [GraphEdge]) -> [String: Int] {
        var incoming: [String: [String]] = [:]
        for edge in edges { incoming[edge.to, default: []].append(edge.from) }
        var layer: [String: Int] = [:]
        func depth(_ node: String) -> Int {
            if let known = layer[node] { return known }
            let value = (incoming[node] ?? []).map { depth($0) + 1 }.max() ?? 0
            layer[node] = value
            return value
        }
        for node in nodes { _ = depth(node) }
        return layer
    }

    /// Moves each repo nothing depends on down to just above the highest of its dependencies. Longest-path layering
    /// puts every such repo in the top layer, so a scope of thirty services that each use one library got a first
    /// row thirty wide, wrapped, its links crossing the rows under it; a service next to what it uses reads better.
    static func sinkSources(_ layers: [String: Int], edges: [GraphEdge]) -> [String: Int] {
        var result = layers
        let targets = Set(edges.map(\.to))
        var outgoing: [String: [String]] = [:]
        for edge in edges { outgoing[edge.from, default: []].append(edge.to) }
        for (node, next) in outgoing where !targets.contains(node) {
            let highest = next.compactMap { layers[$0] }.min() ?? 1
            result[node] = max(0, highest - 1)
        }
        return result
    }

    /// Index of each node's connected component, numbered from the largest component down (ties by first key).
    static func components(nodes: [String], edges: [GraphEdge]) -> [String: Int] {
        var adjacent: [String: [String]] = [:]
        for edge in edges {
            adjacent[edge.from, default: []].append(edge.to)
            adjacent[edge.to, default: []].append(edge.from)
        }
        var groups: [[String]] = []
        var seen = Set<String>()
        for start in nodes where !seen.contains(start) {
            var group: [String] = []
            var stack = [start]
            seen.insert(start)
            while let node = stack.popLast() {
                group.append(node)
                for next in adjacent[node] ?? [] where seen.insert(next).inserted { stack.append(next) }
            }
            groups.append(group.sorted())
        }
        groups.sort { ($1.count, $0[0]) < ($0.count, $1[0]) }
        var index: [String: Int] = [:]
        for (number, group) in groups.enumerated() { for node in group { index[node] = number } }
        return index
    }

    /// Barycentre ordering: each layer sorted by the mean position of its neighbours in the layer above (going
    /// down) or below (going up), ties kept in their previous order. A few sweeps settle most crossings.
    static func orderBySweeps(_ layers: [[String]], edges: [GraphEdge], sweeps: Int = 4) -> [[String]] {
        var layers = layers
        var up: [String: [String]] = [:], down: [String: [String]] = [:]
        for edge in edges {
            down[edge.from, default: []].append(edge.to)
            up[edge.to, default: []].append(edge.from)
        }
        func reorder(_ index: Int, by neighbours: [String: [String]], reference: [String]) {
            let position = Dictionary(uniqueKeysWithValues: reference.enumerated().map { ($1, Double($0)) })
            let previous = Dictionary(uniqueKeysWithValues: layers[index].enumerated().map { ($1, Double($0)) })
            let keyed = layers[index].map { node -> (String, Double) in
                let around = (neighbours[node] ?? []).compactMap { position[$0] }
                return (node, around.isEmpty ? previous[node]! : around.reduce(0, +) / Double(around.count))
            }
            layers[index] = keyed.sorted { ($0.1, previous[$0.0]!) < ($1.1, previous[$1.0]!) }.map(\.0)
        }
        guard layers.count > 1 else { return layers }
        for _ in 0..<sweeps {
            for index in 1..<layers.count { reorder(index, by: up, reference: layers[index - 1]) }
            for index in stride(from: layers.count - 2, through: 0, by: -1) { reorder(index, by: down, reference: layers[index + 1]) }
        }
        return layers
    }
}
