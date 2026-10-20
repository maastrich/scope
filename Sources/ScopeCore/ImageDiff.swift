import Foundation

/// Where two screenshots of the same route differ (`scope_browser_compare`, the Compare view). Pure, on RGBA8
/// buffers of one size: the share of pixels that changed, and the changed areas as rectangles — cells of `cell`
/// pixels with a changed pixel, merged with their neighbours — so the user reads three boxes rather than a haze.
public enum ImageDiff {
    public struct Region: Equatable, Sendable, Codable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Result: Equatable, Sendable {
        /// Changed pixels over all pixels, 0…1.
        public var fraction: Double
        public var regions: [Region]
    }

    /// `threshold` is the largest per-channel difference still called the same (anti-aliasing, a caret).
    public static func compare(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, threshold: Int = 24, cell: Int = 16) -> Result {
        precondition(a.count == width * height * 4 && b.count == a.count, "two RGBA buffers of width × height")
        let columns = (width + cell - 1) / cell
        let rows = (height + cell - 1) / cell
        var marked = [Bool](repeating: false, count: columns * rows)
        var changed = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for y in 0..<height {
                    let line = y * width * 4
                    for x in 0..<width {
                        let i = line + x * 4
                        if abs(Int(a[i]) - Int(b[i])) > threshold || abs(Int(a[i + 1]) - Int(b[i + 1])) > threshold
                            || abs(Int(a[i + 2]) - Int(b[i + 2])) > threshold {
                            changed += 1
                            marked[(y / cell) * columns + x / cell] = true
                        }
                    }
                }
            }
        }
        // Connected cells, eight-way, each component's bounding box.
        var seen = [Bool](repeating: false, count: marked.count)
        var regions: [Region] = []
        for start in marked.indices where marked[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
            while let index = stack.popLast() {
                let cx = index % columns, cy = index / columns
                minX = min(minX, cx); maxX = max(maxX, cx)
                minY = min(minY, cy); maxY = max(maxY, cy)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                        let next = ny * columns + nx
                        if marked[next], !seen[next] {
                            seen[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            let x = minX * cell, y = minY * cell
            regions.append(Region(x: x, y: y, width: min(width, (maxX + 1) * cell) - x, height: min(height, (maxY + 1) * cell) - y))
        }
        regions.sort { ($0.y, $0.x) < ($1.y, $1.x) }
        return Result(fraction: width * height == 0 ? 0 : Double(changed) / Double(width * height), regions: regions)
    }
}

/// Which worktree of a task serves each port: the working directory of the process listening on it, under the
/// deepest worktree path that holds it. What lets Compare put the base branch's server on the left and the task's on
/// the right without being told.
public enum PortWorktrees {
    public struct Worktree: Equatable, Sendable {
        public var key: String
        public var path: String

        public init(key: String, path: String) {
            self.key = key
            self.path = path
        }
    }

    public static func map(listeners: [ListeningPorts.Listener], directories: [Int32: String], worktrees: [Worktree]) -> [Int: String] {
        var owners: [Int: String] = [:]
        for listener in listeners.sorted(by: { ($0.port, $0.pid) < ($1.port, $1.pid) }) where owners[listener.port] == nil {
            guard let directory = directories[listener.pid] else { continue }
            let holder = worktrees.filter { directory == $0.path || directory.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
                .max { $0.path.count < $1.path.count }
            if let holder { owners[listener.port] = holder.key }
        }
        return owners
    }
}
