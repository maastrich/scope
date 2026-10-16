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
            guard let task = task(reading.id), task.listeningPorts != reading.ports else { continue }
            task.listeningPorts = reading.ports
        }
    }

    /// A port chip was clicked: the browser on it.
    func openPort(_ port: Int) {
        openOnGitHub(PortBlock.url(for: port))
    }
}
