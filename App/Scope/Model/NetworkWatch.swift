import Foundation
import Network
import ScopeAssist
import ScopeCore

/// The network path as the acting triggers read it: up or down, and when it last changed — a Wi-Fi drop, another
/// interface, a VPN coming up or going down. `NWPathMonitor` on a queue of its own, its updates hopped to the main
/// actor.
///
/// A Debug build also reads `SCOPE_HOME/debug-network` (`offline` or `online`) every two seconds, so a throwaway
/// instance can rehearse a cut without taking the Mac off the network.
@MainActor
final class NetworkWatch {
    private(set) var state = RelaunchTiming.Network(online: true)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.maastrich.scope.network", qos: .userInitiated)
    private var onChange: (@MainActor () -> Void)?
    private var lastSignature: String?
    #if DEBUG
    private var override: Task<Void, Never>?
    private var forced: Bool?
    #endif

    func start(home: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            // Interfaces and status, not the object: a VPN shows as a new `utun` interface on the same status.
            let signature = "\(path.status)|" + path.availableInterfaces.map { "\($0.name)" }.sorted().joined(separator: ",")
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online: online, signature: signature) }
        }
        monitor.start(queue: queue)
        #if DEBUG
        let file = home.appending(path: "debug-network")
        override = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let word = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self else { return }
                let forced: Bool? = switch word { case "offline": false; case "online": true; default: nil }
                guard forced != self.forced else { continue }
                self.forced = forced
                Log.app.notice("network: debug override \(word ?? "cleared", privacy: .public)")
                self.update(online: forced ?? true, signature: "debug|\(word ?? "")")
            }
        }
        #endif
    }

    private func update(online: Bool, signature: String) {
        #if DEBUG
        // The override holds until the file goes: a real path update must not undo the rehearsal.
        if forced != nil, !signature.hasPrefix("debug|") { return }
        #endif
        guard signature != lastSignature || online != state.online else { return }
        let first = lastSignature == nil
        lastSignature = signature
        // The first report is where the path stands at launch, not a change.
        state = RelaunchTiming.Network(online: online, changedAt: first ? state.changedAt : .now)
        Log.app.info("network: \(online ? "online" : "offline", privacy: .public) (\(signature, privacy: .public))")
        if !first { onChange?() }
    }
}
