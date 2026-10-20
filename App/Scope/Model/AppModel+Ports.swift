import Foundation
import ScopeCore
import ScopeTasks

/// The servers a task is running: every twenty seconds, for each live task with a thread alive, the processes under
/// its root (the sweep's own lookup) are asked which TCP ports they listen on, and the ones inside the task's block
/// become `localhost:41003 ↗` chips in its section and hover card; the ones outside the block and what
/// `.claude/launch.json` declares are kept too, for the task's browser. A task whose threads are all stopped keeps the
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
        let inputs = candidates.map { task in
            (id: task.id, root: task.record.rootURL, block: task.record.portBlock!,
             launchFiles: task.activeSandboxes.map { URL(fileURLWithPath: $0.sandboxPath).appending(path: ".claude/launch.json") },
             // Every spelling of each path: a process reports `/private/tmp/…` for a worktree recorded as `/tmp/…`.
             worktrees: task.activeSandboxes.flatMap { sandbox in
                 ProcessSweep.spellings(URL(fileURLWithPath: sandbox.sandboxPath)).map { PortWorktrees.Worktree(key: sandbox.sandboxKey, path: $0) }
             })
        }
        let readings = await Task.detached(priority: .utility) {
            inputs.map { input in
                let processes = ProcessSweep.processes(under: [input.root])
                let listeners = ListeningPorts.listeners(of: processes.map(\.pid))
                let directories = Dictionary(processes.compactMap { match in match.directory.map { (match.pid, $0) } },
                                             uniquingKeysWith: { first, _ in first })
                let launch = input.launchFiles.flatMap { url in
                    (try? Data(contentsOf: url)).map(LaunchConfig.servers) ?? []
                }
                return (id: input.id, ports: input.block.ports(in: listeners), others: input.block.otherServerPorts(in: listeners),
                        launch: launch,
                        owners: PortWorktrees.map(listeners: listeners, directories: directories, worktrees: input.worktrees))
            }
        }.value
        for reading in readings {
            guard let task = task(reading.id) else { continue }
            if task.listeningPorts != reading.ports { task.listeningPorts = reading.ports }
            if task.otherPorts != reading.others { task.otherPorts = reading.others }
            if task.launchServers != reading.launch { task.launchServers = reading.launch }
            if task.portWorktrees != reading.owners { task.portWorktrees = reading.owners }
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
                    ListeningProcesses.commandLine(arguments: ProcessSweep.arguments(pid))
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

    /// A port chip of `task` was clicked: the task's Browser pane on it, or the system browser (`BrowserRoute`).
    func openPort(_ port: Int, of task: TaskState) {
        openWebLink(PortBlock.url(for: port).absoluteString, task: task)
    }
}
