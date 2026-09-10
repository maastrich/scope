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
}
