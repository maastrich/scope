import Foundation
import ScopeCore
import ScopeTasks

/// The servers a task is running: every twenty seconds, for each live task with a thread alive, the processes under
/// its root (the sweep's own lookup) are asked which TCP ports they listen on, and the ones inside the task's block
/// become `localhost:41003 ↗` chips in its section and hover card. A task whose threads are all stopped keeps the
/// last reading until its next thread, so the chips do not blink on a relaunch.
extension AppModel {
    static let portScanInterval: Duration = .seconds(20)

    func startPortScanning() {
        portScanner?.cancel()
        portScanner = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanPorts()
                try? await Task.sleep(for: AppModel.portScanInterval)
            }
        }
    }

    /// One pass over the tasks worth scanning, off the main actor; the results land on each `TaskState`.
    func scanPorts() async {
        let candidates = tasks.filter { task in
            !task.isArchived && task.record.portBlock != nil && threads(in: task.id).contains(where: \.isAlive)
        }
        guard !candidates.isEmpty else { return }
        let inputs = candidates.map { (id: $0.id, root: $0.record.rootURL, block: $0.record.portBlock!) }
        let readings = await Task.detached(priority: .utility) {
            inputs.map { input in
                let pids = ProcessSweep.processes(under: [input.root]).map(\.pid)
                return (id: input.id, ports: input.block.ports(in: ListeningPorts.listeners(of: pids)))
            }
        }.value
        for reading in readings {
            guard let task = task(reading.id) else { continue }
            if task.listeningPorts != reading.ports { task.listeningPorts = reading.ports }
            // The processes go with the ports: same pass, same twenty seconds, only for a card that shows them.
            if processWatchers.contains(task.id) { refreshListeningProcesses(of: task) }
        }
    }

    /// The Environment card of `task` opened or closed: its listening processes are read while it is open, and
    /// right away on opening so the lines do not wait for the next pass.
    func watchListeningProcesses(of task: TaskState, _ watching: Bool) {
        if watching {
            processWatchers.insert(task.id)
            refreshListeningProcesses(of: task)
        } else {
            processWatchers.remove(task.id)
        }
    }

    /// Who holds the task's listening ports: one `lsof` over them, off the main actor, each process named by its
    /// `argv` and tied to the thread it was started from (`ListeningProcesses.owner`). Coalesced per task; nothing
    /// listening means nothing to run.
    func refreshListeningProcesses(of task: TaskState) {
        let id = task.id
        let ports = task.listeningPorts
        guard !ports.isEmpty else {
            if !task.listeningProcesses.isEmpty { task.listeningProcesses = [] }
            return
        }
        guard processRuns[id] == nil else { return }
        let shells = Dictionary(threads(in: id).compactMap { session in session.pid.map { ($0, session.id.rawValue) } },
                                uniquingKeysWith: { first, _ in first })
        processRuns[id] = Task { [weak self] in
            let processes = await Task.detached(priority: .utility) { () -> [ListeningProcesses.Process]? in
                guard let result = try? await Subprocess.run(executable: "/usr/sbin/lsof",
                                                              arguments: ListeningProcesses.lsofArguments(ports: ports),
                                                              timeout: .seconds(10)) else { return nil }
                // `lsof` exits 1 when nothing matched: an empty list, not a failure.
                let entries = ListeningProcesses.parse(result.stdoutText)
                return ListeningProcesses.processes(entries) { pid in
                    ProcessSweep.arguments(pid).joined(separator: " ")
                } owner: { pid in
                    ListeningProcesses.owner(of: pid, threads: shells, environment: ProcessSweep.environment, parent: ProcessSweep.parent)
                }
            }.value
            guard let self else { return }
            processRuns[id] = nil
            guard let processes, let task = self.task(id), task.listeningProcesses != processes else { return }
            task.listeningProcesses = processes
        }
    }

    /// A port chip was clicked: the browser on it.
    func openPort(_ port: Int) {
        openOnGitHub(PortBlock.url(for: port))
    }
}
