import Foundation
import Testing
@testable import ScopeControl

/// Putting `scope` on the user's own PATH: one symlink into the app bundle, never a copy.
@Suite struct CLIInstallerTests {
    static func temporaryHome() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "scope-install-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in for the tool inside the app bundle.
    static func fakeTool(in home: URL) throws -> String {
        let path = home.appending(path: "scope").path
        #expect(FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                               attributes: [.posixPermissions: 0o755]))
        return path
    }

    @Test func installLinksAndIsIdempotent() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let tool = try Self.fakeTool(in: home)
        let destination = CLIInstaller.Destination.scopeHome(home)

        #expect(CLIInstaller.state(of: destination, toolPath: tool) == .absent)
        let link = try CLIInstaller.install(toolPath: tool, to: destination)
        #expect(link == home.appending(path: "bin/scope").path)
        #expect(CLIInstaller.state(of: destination, toolPath: tool) == .installed(at: link))
        #expect(try CLIInstaller.install(toolPath: tool, to: destination) == link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == tool)
    }

    /// An app that moved, or a second copy: the link is repointed rather than left stale.
    @Test func installRepointsItsOwnLink() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = try Self.fakeTool(in: home)
        let destination = CLIInstaller.Destination.scopeHome(home)
        try CLIInstaller.install(toolPath: old, to: destination)

        let moved = home.appending(path: "moved", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let new = try Self.fakeTool(in: moved)
        #expect(CLIInstaller.state(of: destination, toolPath: new) != .installed(at: destination.linkPath))
        try CLIInstaller.install(toolPath: new, to: destination)
        #expect(CLIInstaller.state(of: destination, toolPath: new) == .installed(at: destination.linkPath))
    }

    /// Somebody else's `scope` is left exactly where it is.
    @Test func aRealFileIsNeverOverwritten() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let tool = try Self.fakeTool(in: home)
        let destination = CLIInstaller.Destination.scopeHome(home)
        try FileManager.default.createDirectory(atPath: destination.directory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: destination.linkPath, contents: Data("theirs".utf8)))

        #expect(throws: ControlError.self) { try CLIInstaller.install(toolPath: tool, to: destination) }
        #expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: destination.linkPath)), as: UTF8.self) == "theirs")
    }

    @Test func uninstallRemovesOnlyOurLink() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let tool = try Self.fakeTool(in: home)
        let destination = CLIInstaller.Destination.scopeHome(home)
        try CLIInstaller.install(toolPath: tool, to: destination)
        try CLIInstaller.uninstall(from: destination, toolPath: tool)
        #expect(CLIInstaller.state(of: destination, toolPath: tool) == .absent)
    }

    @Test func aMissingToolIsRefusedBeforeAnythingIsWritten() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let destination = CLIInstaller.Destination.scopeHome(home)
        #expect(throws: ControlError.self) {
            try CLIInstaller.install(toolPath: home.appending(path: "nope").path, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.linkPath))
    }

    @Test func aHomeInstallSaysHowToReachIt() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CLIInstaller.pathAdvice(for: .scopeHome(home))?.contains(home.appending(path: "bin").path) == true)
        #expect(CLIInstaller.pathAdvice(for: .usrLocalBin) == nil)
    }

    /// Both builds have installed `scope` in the same place: the installed copy keeps the name.
    @Test func aDebugBuildNeverTakesOverTheInstalledLink() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let release = try Self.fakeTool(in: home)
        let destination = CLIInstaller.Destination.scopeHome(home)
        try CLIInstaller.install(toolPath: release, to: destination)

        let derivedData = home.appending(path: "DerivedData", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let debug = try Self.fakeTool(in: derivedData)

        #expect(CLIInstaller.state(of: destination, toolPath: debug) == .foreign(at: destination.linkPath, target: release))
        do {
            try CLIInstaller.install(toolPath: debug, to: destination, debugBuild: true)
            Issue.record("a Debug build must not repoint a live link")
        } catch let error as ControlError {
            // Loud, and it names what it left alone.
            #expect(error.detail?.contains(release) == true)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.linkPath) == release)
        #expect(CLIInstaller.state(of: destination, toolPath: release) == .installed(at: destination.linkPath))
    }

    /// A link left by a build that no longer exists is nobody's: a Debug build may have it.
    @Test func aDebugBuildReplacesADeadLink() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let destination = CLIInstaller.Destination.scopeHome(home)
        try FileManager.default.createDirectory(atPath: destination.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: destination.linkPath, withDestinationPath: home.path + "/gone/scope")

        let debug = try Self.fakeTool(in: home)
        try CLIInstaller.install(toolPath: debug, to: destination, debugBuild: true)
        #expect(CLIInstaller.state(of: destination, toolPath: debug) == .installed(at: destination.linkPath))
        // Its own link stays its own.
        #expect(try CLIInstaller.install(toolPath: debug, to: destination, debugBuild: true) == destination.linkPath)
    }

    /// `/usr/local/bin/scope` is one name for the whole machine: only the installed copy may claim it.
    @Test func aDebugBuildOnlyInstallsUnderItsOwnHome() {
        final class Writable: FileManager, @unchecked Sendable {
            override func isWritableFile(atPath path: String) -> Bool { true }
        }
        let debugHome = URL(fileURLWithPath: "/Users/me/.scope-debug", isDirectory: true)
        #expect(CLIInstaller.preferredDestination(home: debugHome, debugBuild: true, fileManager: Writable()) == .scopeHome(debugHome))
        #expect(CLIInstaller.preferredDestination(home: debugHome, fileManager: Writable()) == .usrLocalBin)
        #expect(CLIInstaller.Destination.scopeHome(debugHome).linkPath == "/Users/me/.scope-debug/bin/scope")
    }
}

/// `scope --version` is the version of the app it ships inside.
@Suite struct ScopeCLIVersionTests {
    @Test func theVersionComesFromTheEnclosingBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "Scope-\(UUID().uuidString.prefix(8)).app/Contents", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let helpers = root.appending(path: "Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "0.4.1"], format: .xml, options: 0)
        try plist.write(to: root.appending(path: "Info.plist"))

        #expect(ScopeCLIVersion.bundleVersion(forExecutableAt: helpers.appending(path: "scope").path) == "0.4.1")
    }

    @Test func aToolOutsideABundleHasNoVersionToRead() {
        #expect(ScopeCLIVersion.bundleVersion(forExecutableAt: "/usr/local/bin/scope") == nil)
        #expect(ScopeCLIVersion.bundleVersion(forExecutableAt: "") == nil)
        #expect(ScopeCLIVersion.resolve(environment: [:], executable: "/tmp/scope") == "dev")
    }

    @Test func theEnvironmentWins() {
        #expect(ScopeCLIVersion.resolve(environment: ["SCOPE_CLI_VERSION": "9.9.9"], executable: "/tmp/scope") == "9.9.9")
    }
}
