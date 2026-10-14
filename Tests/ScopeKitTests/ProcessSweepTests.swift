import Foundation
import Testing
@testable import ScopeCore

@Suite(.serialized) struct ProcessSweepTests {
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "scope-sweep-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func spawn(_ script: String, in directory: URL, environment: [String: String] = [:]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        try process.run()
        return process
    }

    /// The kernel hides the environment of Apple's platform binaries; an ad-hoc signed copy of `sleep` is
    /// what a dev server or an agent looks like to it.
    private func ordinarySleep(in directory: URL) throws -> URL {
        let copy = directory.appending(path: "sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", copy.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        return copy
    }

    @Test func stopsWhatRunsInsideOrNamesTheRootAndLeavesTheRest() async throws {
        let root = try folder("task")
        let elsewhere = try folder("elsewhere")
        let sleep = try ordinarySleep(in: elsewhere)
        let inside = try spawn("exec sleep 60", in: root)
        let stubborn = try spawn("trap '' TERM; sleep 60 & wait", in: root)
        let named = try spawn("exec '\(sleep.path)' 60", in: elsewhere, environment: ["SCOPE_TASK_ROOT": root.path])
        let bystander = try spawn("exec sleep 60", in: elsewhere)
        defer { bystander.terminate() }
        try await Task.sleep(for: .milliseconds(300))

        let found = Set(ProcessSweep.processes(under: [root]).map(\.pid))
        #expect(found.isSuperset(of: [inside.processIdentifier, stubborn.processIdentifier, named.processIdentifier]))
        #expect(!found.contains(bystander.processIdentifier))

        let result = await ProcessSweep.stop(under: [root], grace: .milliseconds(500))
        #expect(result.survivors.isEmpty)
        #expect(Set(result.stopped.map(\.pid)).isSuperset(of: [inside.processIdentifier, stubborn.processIdentifier]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!inside.isRunning && !stubborn.isRunning && !named.isRunning)
        #expect(bystander.isRunning)
        #expect(ProcessSweep.processes(under: [root]).isEmpty)
    }

    @Test func aShallowRootMatchesNothing() {
        #expect(ProcessSweep.processes(under: [URL(fileURLWithPath: "/")]).isEmpty)
        #expect(ProcessSweep.processes(under: [URL(fileURLWithPath: "/Users")]).isEmpty)
    }
}
