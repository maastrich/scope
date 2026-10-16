import Foundation
import ScopeCore
import ScopeTasks

/// Tasks started from other tasks (`TaskRecord.parentTask`): the sidebar links a child to its parent rather than
/// nesting it, since a child usually shares its parent's topic and the topic already gathers them.
extension AppModel {
    /// The task `task` was started from, while its record is still around (archived or not).
    func parentTask(of task: TaskState) -> TaskState? {
        task.record.parentTask.flatMap { self.task($0) }
    }

    /// The tasks started from `task` that are not archived, in creation order.
    func childTasks(of task: TaskState) -> [TaskState] {
        tasks.filter { $0.record.parentTask == task.id && !$0.isArchived }
    }

    /// Selects `task` from a link to it: its topic unfolds so the row it lands on is in view.
    func selectLinkedTask(_ task: TaskState) {
        guard !task.isArchived else { return }
        if let topic = task.record.topic, let scope = scope(task.scopeID) {
            scope.collapsedTopics.remove(TaskTopic.key(topic))
        }
        selection = .task(task.id)
    }
}
