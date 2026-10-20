import Foundation
import ScopeCore

/// What a task row shows beyond its name, decided from its status alone so the sidebar and the tests agree.
///
/// A compact row is the default: one line, the glyph, the name, and one mark at the end. The second line comes
/// back only while the task is waiting for the user or working — the two states where what the agent is doing is
/// worth a line — and leaves once it is quiet again. Detailed rows (`⌃⌘L`) keep it on every row.
///
/// The end of the row carries one indicator and never two: the state dot of the task's threads, or, on a one-line
/// row of a task whose pull requests have all landed, a `merged` chip — the dot would say *idle* about a task whose
/// only news is that it is done. A detailed row's second line already says *merged*, so it keeps the dot.
public enum SidebarTaskRowPolicy {
    public enum Trailing: Equatable, Sendable {
        /// The threads' state, in the shapes `StateDot` gives it.
        case stateDot
        /// A quiet `merged` chip in `PullRequestStyle.passing` ink.
        case mergedChip
    }

    /// Whether the row carries a second line.
    public static func showsSecondLine(rows: SidebarRows, status: TaskStatus) -> Bool {
        switch rows {
        case .detailed: true
        case .compact: isBusy(status)
        }
    }

    /// Waiting for the user, or working: the states whose rows stay two lines even when compact.
    public static func isBusy(_ status: TaskStatus) -> Bool {
        switch SidebarGroup(status) {
        case .needsYou, .working: true
        case .finished, .quiet, .dormant: false
        }
    }

    /// The one mark at the end of the row.
    public static func trailing(status: TaskStatus, secondLine: Bool) -> Trailing {
        status == .merged && !secondLine ? .mergedChip : .stateDot
    }

    /// The row's height for its status under the setting.
    public static func height(rows: SidebarRows, status: TaskStatus) -> Double {
        SidebarRowLayout.height(detailed: showsSecondLine(rows: rows, status: status))
    }
}

extension SidebarGroup {
    /// A group header and what it counts.
    public struct Section: Equatable, Sendable {
        public var group: SidebarGroup
        public var count: Int

        public init(group: SidebarGroup, count: Int) {
            self.group = group
            self.count = count
        }

        public var title: String { group.title }
    }

    /// The headers of the sidebar arranged by state, most pressing first, each with the number of rows under it;
    /// a group with nothing under it is left out rather than shown empty.
    public static func sections(_ groups: [SidebarGroup]) -> [Section] {
        allCases.sorted().compactMap { group in
            let count = groups.filter { $0 == group }.count
            return count == 0 ? nil : Section(group: group, count: count)
        }
    }
}
