import Foundation
import ScopeGit

/// Which version of a file a diff line belongs to.
public enum DiffSide: String, Codable, Sendable, Equatable, Hashable {
    /// The file before the change (a deleted line).
    case old
    /// The file as it is now (an added or context line).
    case new
}

/// A comment on some lines of a task's diff, kept until it is sent to one of the task's threads.
public struct ReviewComment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// `TaskRepo.repoRelativePath` of the repository.
    public var repo: String
    /// The file, relative to the repository (the new path of a rename).
    public var path: String
    public var side: DiffSide
    public var anchor: ReviewAnchor
    public var body: String
    public var createdAt: Date

    public init(id: UUID = UUID(), repo: String, path: String, side: DiffSide, anchor: ReviewAnchor, body: String,
                createdAt: Date = .now) {
        self.id = id
        self.repo = repo
        self.path = path
        self.side = side
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
    }
}

/// Where a comment points, recorded so it can be found again after the agent kept editing the file.
///
/// Line numbers drift the moment anything above changes, so they are only the tie-breaker: the anchor is the
/// exact text of the first line, the lines around it and the span. `locate` searches the current file for that
/// shape; the stored lines are the fallback when it is gone.
public struct ReviewAnchor: Codable, Sendable, Hashable {
    /// 1-based line number on the comment's side, when the comment was written.
    public var line: Int
    /// Number of lines the comment covers (at least 1).
    public var span: Int
    /// The commented lines as they were; `lines[0]` is the exact first line.
    public var lines: [String]
    /// Up to `contextSize` lines just above, nearest last.
    public var before: [String]
    /// Up to `contextSize` lines just below.
    public var after: [String]

    public static let contextSize = 3

    public init(line: Int, span: Int, lines: [String], before: [String], after: [String]) {
        self.line = line
        self.span = max(1, span)
        self.lines = lines
        self.before = before
        self.after = after
    }

    public var firstLine: String { lines.first ?? "" }
    public var lastLine: Int { line + span - 1 }

    /// The anchor of `side[start...end]`, where `side` is every known line of one side of the file in order,
    /// with its number. The context is taken from the same list.
    public static func make(side: [(number: Int, text: String)], start: Int, end: Int) -> ReviewAnchor {
        let lower = max(0, min(start, end))
        let upper = min(side.count - 1, max(start, end))
        let covered = side[lower...upper]
        return ReviewAnchor(
            line: covered.first?.number ?? 1, span: covered.count, lines: covered.map(\.text),
            before: side[max(0, lower - contextSize)..<lower].map(\.text),
            after: side[(upper + 1)..<min(side.count, upper + 1 + contextSize)].map(\.text)
        )
    }

    /// The 1-based line where the anchor sits in `file` now, or `nil` when it cannot be found with confidence.
    ///
    /// Every line equal to the first line is a candidate, scored by how many of the context lines and of the
    /// span's other lines are still around it; the closest to the old line number wins a tie. A line as common as
    /// `}` with nothing around it matching anymore is not the same place, so it is refused rather than guessed.
    public func locate(in file: [String]) -> Int? {
        let candidates = file.indices.filter { file[$0] == firstLine }
        guard !candidates.isEmpty else { return nil }
        func score(_ index: Int) -> Int {
            var total = 0
            for (offset, text) in before.reversed().enumerated() {
                let at = index - 1 - offset
                if at >= 0, file[at] == text { total += 1 }
            }
            for (offset, text) in lines.dropFirst().enumerated() {
                let at = index + 1 + offset
                if at < file.count, file[at] == text { total += 1 }
            }
            for (offset, text) in after.enumerated() {
                let at = index + span + offset
                if at < file.count, file[at] == text { total += 1 }
            }
            return total
        }
        let scored = candidates.map { (index: $0, score: score($0), distance: abs($0 + 1 - line)) }
        let best = scored.max { ($0.score, -$0.distance) < ($1.score, -$1.distance) }!
        if best.score == 0 {
            let distinctive = firstLine.trimmingCharacters(in: .whitespaces).count > 2
            guard candidates.count == 1, distinctive else { return nil }
        }
        return best.index + 1
    }
}

// MARK: - Comments and diffs

/// Where comments sit in a diff: what can be commented, what a selection means, and which line each comment hangs
/// under. Lines are addressed by their index in `commentableLines`, the order the diff view draws them.
public enum ReviewPlacement {
    /// Every hunk line in order, the `\ No newline at end of file` markers left out.
    public static func commentableLines(of file: DiffFile) -> [DiffLine] {
        file.hunks.flatMap(\.lines).filter { $0.kind != .noNewline }
    }

    /// The side and the anchor of the selection `lines[start...end]`. The side is the first line's: a selection
    /// starting on a removed line is about the old file, anything else about the new one. Lines of the other side
    /// inside the selection are skipped; `nil` when none of the chosen side is left.
    public static func anchor(for lines: [DiffLine], start: Int, end: Int) -> (side: DiffSide, anchor: ReviewAnchor)? {
        guard lines.indices.contains(start), lines.indices.contains(end) else { return nil }
        let lower = min(start, end)
        let upper = max(start, end)
        let side: DiffSide = lines[lower].newLineNumber != nil ? .new : .old
        let sideLines = numbered(lines, side: side)
        guard let first = sideLines.firstIndex(where: { $0.index >= lower }),
              let last = sideLines.lastIndex(where: { $0.index <= upper }), first <= last else { return nil }
        return (side, ReviewAnchor.make(side: sideLines.map { ($0.number, $0.text) }, start: first, end: last))
    }

    /// The line each comment is drawn under — the last of its lines, found again by content — and the comments
    /// whose lines are no longer in this diff.
    public static func place(_ comments: [ReviewComment], in lines: [DiffLine]) -> (placed: [Int: [ReviewComment]], orphans: [ReviewComment]) {
        var placed: [Int: [ReviewComment]] = [:]
        var orphans: [ReviewComment] = []
        for comment in comments.sorted(by: { $0.createdAt < $1.createdAt }) {
            let sideLines = numbered(lines, side: comment.side)
            guard let at = comment.anchor.locate(in: sideLines.map(\.text)) else {
                orphans.append(comment)
                continue
            }
            let last = min(at - 1 + comment.anchor.span - 1, sideLines.count - 1)
            placed[sideLines[last].index, default: []].append(comment)
        }
        return (placed, orphans)
    }

    private static func numbered(_ lines: [DiffLine], side: DiffSide) -> [(index: Int, number: Int, text: String)] {
        lines.enumerated().compactMap { index, line in
            (side == .new ? line.newLineNumber : line.oldLineNumber).map { (index, $0, line.text) }
        }
    }
}
