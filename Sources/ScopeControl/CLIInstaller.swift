import Foundation
import ScopeCore

/// Puts `scope` on the user's own PATH, the way an editor's "install the shell command" does.
///
/// Inside a thread nothing needs installing — Scope puts its `Contents/Helpers` first on the PATH it hands
/// the driver. This is for the terminal the user opens themselves: one symlink, pointing at the copy inside
/// the app bundle, so an update moves with the app instead of leaving a stale binary behind.
public enum CLIInstaller {
    /// Where the link goes, in order of preference.
    public enum Destination: Sendable, Equatable {
        /// `/usr/local/bin` — already on everyone's PATH, writable on a machine that has Homebrew.
        case usrLocalBin
        /// `<SCOPE_HOME>/bin` — always writable, and the user is told to add it to their PATH.
        case scopeHome(URL)

        public var directory: String {
            switch self {
            case .usrLocalBin: "/usr/local/bin"
            case .scopeHome(let home): home.appending(path: "bin", directoryHint: .isDirectory).path
            }
        }

        public var linkPath: String { directory + "/" + ScopeCLIName }
    }

    /// What the link is right now.
    public enum State: Sendable, Equatable {
        /// No `scope` on the PATH and no link of ours.
        case absent
        /// Our link, pointing at this app.
        case installed(at: String)
        /// A `scope` that is not ours (another install, a link to another copy of the app).
        case foreign(at: String, target: String)
    }

    /// Name of the tool; `ScopeCLILocator.name` without a dependency on ScopeDrivers.
    public static let ScopeCLIName = "scope"

    /// Reads the state of `destination` for an app whose tool is at `toolPath`.
    public static func state(of destination: Destination, toolPath: String,
                             fileManager: FileManager = .default) -> State {
        let link = destination.linkPath
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link) else {
            return fileManager.fileExists(atPath: link) ? .foreign(at: link, target: link) : .absent
        }
        return target == toolPath ? .installed(at: link) : .foreign(at: link, target: target)
    }

    /// The destination to use: `/usr/local/bin` when it exists and is writable, else `<home>/bin`.
    public static func preferredDestination(home: URL, fileManager: FileManager = .default) -> Destination {
        let usrLocal = Destination.usrLocalBin.directory
        if fileManager.isWritableFile(atPath: usrLocal) { return .usrLocalBin }
        return .scopeHome(home)
    }

    /// Creates (or repoints) the symlink. Returns where it landed.
    /// - Throws: `ControlError` with a message meant for a dialog.
    @discardableResult
    public static func install(toolPath: String, to destination: Destination,
                               fileManager: FileManager = .default) throws -> String {
        guard fileManager.isExecutableFile(atPath: toolPath) else {
            throw ControlError.failed("the `scope` tool is missing from the app bundle", detail: toolPath)
        }
        let directory = destination.directory
        do {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw ControlError.failed("could not create \(directory)", detail: String(describing: error))
        }
        let link = destination.linkPath
        // Replace our own link or a dead one; never a real file we did not create.
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: link) {
            guard existing != toolPath else { return link }
            try? fileManager.removeItem(atPath: link)
        } else if fileManager.fileExists(atPath: link) {
            throw ControlError.failed("\(link) already exists and is not a link Scope made",
                                      detail: "Remove it yourself, then try again.")
        }
        do {
            try fileManager.createSymbolicLink(atPath: link, withDestinationPath: toolPath)
        } catch {
            throw ControlError.failed("could not link \(link)", detail: String(describing: error))
        }
        return link
    }

    /// Removes the link, if it is ours.
    public static func uninstall(from destination: Destination, toolPath: String,
                                 fileManager: FileManager = .default) throws {
        guard case .installed(let link) = state(of: destination, toolPath: toolPath, fileManager: fileManager) else { return }
        do {
            try fileManager.removeItem(atPath: link)
        } catch {
            throw ControlError.failed("could not remove \(link)", detail: String(describing: error))
        }
    }

    /// The line to show under a `<home>/bin` install: it is not on the PATH until the user says so.
    public static func pathAdvice(for destination: Destination) -> String? {
        switch destination {
        case .usrLocalBin: nil
        case .scopeHome(let home):
            "Add it to your PATH: export PATH=\"\(home.appending(path: "bin").path):$PATH\""
        }
    }
}
