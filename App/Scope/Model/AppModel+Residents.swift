import Foundation
import ScopeCore
import ScopeDrivers

/// The orchestrator and the terminal every declared scope keeps at its root (`ResidentRole`). They are ordinary
/// threads; what is theirs is here: Scope creates them, starts them when their scope is shown, starts them again
/// when they die on their own, and `close` refuses them.
extension AppModel {
    /// Gives every declared scope its two resident threads, and makes ordinary threads of the extra claimants
    /// (`ResidentReconciliation`). Creates records, never processes: called at launch, for the scopes declared before
    /// residents existed too, and after a scope is declared.
    func reconcileResidents() async {
        let plan = ResidentReconciliation.reconcile(threads.map(\.record), scopes: scopes.map(\.id))
        for id in plan.demoted {
            session(id)?.setResident(nil)
        }
        for missing in plan.missing {
            await createResident(missing.role, in: missing.scopeID)
        }
        // A record restored with a driver that is no longer the one its role calls for (a changed preference, a
        // missing profile the restore replaced with a shell) is put right while nothing runs in it.
        for session in threads where session.record.resident != nil {
            _ = conformResident(session)
        }
    }

    @discardableResult
    private func createResident(_ role: ResidentRole, in scopeID: ScopeID) async -> ThreadSession? {
        guard let scope = scope(scopeID) else { return nil }
        guard let profile = residentProfile(for: role) else {
            Log.app.warning("no driver profile for the \(role.rawValue, privacy: .public) of \(scope.name, privacy: .public)")
            return nil
        }
        let record = ThreadRecord(
            scopeID: scopeID,
            scopeRoot: scope.declaration.path,
            driverID: profile.id,
            title: role.title,
            cwd: scope.declaration.path,
            cwdKind: .scopeRoot,
            origin: .user,
            resident: role
        )
        // Not `newThread`: that one takes the selection, launches, and makes the driver the scope's next ⌘T.
        let session = ThreadSession(record: record, profile: profile)
        register(session)
        await env.threadRecords.save(record)
        return session
    }

    /// The profile a resident of `role` runs: the shell for the terminal; for the orchestrator its preference, else the
    /// default driver, else the first agent profile installed. Never the shell — an orchestrator falling back on one
    /// would make the scope's second terminal, not its orchestrator — so `nil` when there is no agent at all.
    func residentProfile(for role: ResidentRole) -> DriverProfile? {
        switch role {
        case .terminal:
            return drivers.profile(id: ResidentRole.terminalDriverID)
                ?? DriverProfile(id: ResidentRole.terminalDriverID, name: "Shell", command: "$SHELL", loginShell: true)
        case .orchestrator:
            let preferences = config.preferences
            for id in [preferences.orchestratorDriverID, preferences.defaultDriverID] where id != ResidentRole.terminalDriverID {
                if let profile = drivers.profile(id: id) { return profile }
            }
            return drivers.profiles.first { $0.id != ResidentRole.terminalDriverID }
        }
    }

    /// The session to start for `session`: itself, or — for a stopped resident whose driver is not the one its role
    /// calls for any more — a new session in its place with that driver and no session to resume, since a resume id
    /// belongs to the driver that issued it. A running one keeps its driver until it next starts.
    func conformResident(_ session: ThreadSession) -> ThreadSession {
        guard let role = session.record.resident, !session.isAlive, let wanted = residentProfile(for: role),
              wanted.id != session.profile.id || wanted.id != session.record.driverID else { return session }
        var record = session.record
        record.driverID = wanted.id
        record.resumeID = nil
        let replacement = ThreadSession(record: record, profile: wanted)
        AdapterInstaller.remove(profile: session.profile, threadID: session.id, home: env.home)
        replace(session, with: replacement)
        Task { await env.threadRecords.save(record) }
        return replacement
    }

    /// Starts the residents of `scopeID` that are not running, unless Scope is holding them (`ResidentHold`), they are
    /// already starting, or the scope's folder is not there. Called when a scope is shown.
    func startResidents(in scopeID: ScopeID) {
        guard !isTerminating, let scope = scope(scopeID), ScopeState.rootExists(scope.url) else { return }
        for found in residents(in: scopeID) where !found.isAlive && residentHolds[found.id] == nil {
            if case .launching = found.phase { continue }
            if residentRestarts[found.id] != nil { continue }
            let session = conformResident(found)
            // Marked now, not in the task: a second call before the task runs must see it starting.
            session.markLaunching()
            Task { await launch(session, mode: .relaunch(profile: session.profile, resumeID: session.record.resumeID)) }
        }
    }

    /// A resident's process ended while the app runs. Stopped on request: it stays stopped. Gone with its folder: it
    /// starts when the scope is shown again with the folder back. Otherwise `ResidentRestart` decides.
    func residentExited(_ session: ThreadSession, status: ExitStatus, requested: Bool) {
        let id = session.id
        guard !requested else {
            residentHolds[id] = .stopped
            residentQuickExits[id] = nil
            return
        }
        guard let scope = scope(session.record.scopeID), ScopeState.rootExists(scope.url) else { return }
        let ranFor = session.record.lastLaunchedAt.map { Duration.seconds(status.at.timeIntervalSince($0)) }
        let (decision, quickExits) = ResidentRestart.decide(status, ranFor: ranFor, quickExits: residentQuickExits[id] ?? 0)
        residentQuickExits[id] = quickExits
        switch decision {
        case .hold(let hold):
            residentHolds[id] = hold
            problems.report(Problem(
                severity: .warning,
                title: "The \(session.record.resident?.rawValue ?? "resident thread") of \(scope.name) is stopped",
                detail: "Not restarted: \(hold.reason) (\(status.summary)). Relaunch starts it again.",
                scopeID: scope.id,
                threadID: id,
                actions: [ProblemAction(title: "Relaunch", kind: .retryLaunch(id)),
                          ProblemAction(title: "Open Settings", kind: .openSettings)]
            ))
        case .restart(let delay, let fresh):
            session.printNotice("\(status.summary) · Scope starts it again")
            residentRestarts[id] = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, !self.isTerminating else { return }
                self.residentRestarts[id] = nil
                guard let current = self.session(id), !current.isAlive, self.residentHolds[id] == nil else { return }
                let next = self.conformResident(current)
                await self.launch(next, mode: fresh ? .launch : .relaunch(profile: next.profile, resumeID: next.record.resumeID))
            }
        }
    }

    /// ⇧ at launch left the open scope's residents stopped: held like a Stop, so showing the scope does not start
    /// them behind the user's back. Relaunch does.
    func holdResidentsSkippedAtLaunch(_ ids: [ThreadID]) {
        for id in ids where session(id)?.record.resident != nil {
            residentHolds[id] = .skippedOnce
        }
    }
}
