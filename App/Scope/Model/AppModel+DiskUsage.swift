import Foundation
import ScopeCore
import ScopeTasks

/// How much disk the sandboxes take: each live task's root walked off the main actor, the figure cached on its
/// `TaskState`, measured again after a setup, a restore, and every ten minutes while the app runs. The Task section
/// shows a task's, the scope's settings sheet the total with the three heaviest tasks.
extension AppModel {
    static let diskUsageInterval: Duration = .seconds(10 * 60)

    func startDiskUsageRefresh() {
        diskUsageRefresher?.cancel()
        diskUsageRefresher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDiskUsage()
                try? await Task.sleep(for: AppModel.diskUsageInterval)
            }
        }
    }

    /// Every live task, one after the other: the walks are I/O bound and two at once only fight over the disk.
    func refreshDiskUsage() async {
        for task in tasks where !task.isArchived {
            await measureDiskUsage(of: task)
        }
    }

    /// One task, now, in the background. Coalesced per task: a second request while one runs is dropped.
    func refreshDiskUsage(of task: TaskState) {
        let id = task.id
        guard diskUsageRuns[id] == nil else { return }
        diskUsageRuns[id] = Task { [weak self] in
            await self?.measureDiskUsage(of: task)
            self?.diskUsageRuns[id] = nil
        }
    }

    private func measureDiskUsage(of task: TaskState) async {
        guard !task.isArchived else { return }
        let root = task.record.rootURL
        let bytes = await Task.detached(priority: .utility) { SandboxSize.bytes(under: root) }.value
        guard self.task(task.id) != nil, !task.isArchived else { return }
        task.diskUsage = SandboxSize.Measurement(bytes: bytes)
    }

    /// What the scope's live tasks take together, and the heaviest three, from the cached measurements.
    func diskUsage(in scopeID: ScopeID) -> (total: Int64, measured: Int, largest: [(task: TaskState, bytes: Int64)]) {
        let measured = tasks(in: scopeID).compactMap { task in task.diskUsage.map { (task: task, bytes: $0.bytes) } }
        let total = measured.reduce(Int64(0)) { $0 + $1.bytes }
        let largest = SandboxSize.largest(Dictionary(measured.map { ($0.task.id, $0.bytes) }, uniquingKeysWith: { $1 }))
            .compactMap { entry in task(entry.key).map { (task: $0, bytes: entry.bytes) } }
        return (total, measured.count, largest)
    }
}
