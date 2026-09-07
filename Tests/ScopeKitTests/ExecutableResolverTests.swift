import Foundation
import ScopeDrivers
import Testing

/// A temp tree with `a/`, `b/` and a fake home, for PATH and `~` resolution.
private struct ResolverFixture {
    let root: URL
    var a: URL { root.appending(path: "a") }
    var b: URL { root.appending(path: "b") }
    var home: URL { root.appending(path: "home") }
    var path: String { "\(a.path):\(b.path)" }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "scope-resolver-\(UUID().uuidString)")
        for directory in [a, b, home.appending(path: "bin")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Writes a tiny script; `executable: false` leaves it 0644.
    @discardableResult
    func file(_ relative: String, executable: Bool = true) throws -> String {
        let url = root.appending(path: relative)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("ExecutableResolver")
struct ExecutableResolverTests {
    @Test("$SHELL resolves to the shell when it is executable")
    func shellPlaceholder() {
        #expect(ExecutableResolver.resolve("$SHELL", path: "", shell: "/bin/sh") == "/bin/sh")
        #expect(ExecutableResolver.resolve("$SHELL", path: "/bin", shell: "/nonexistent/fish") == nil)
    }

    @Test("absolute paths are checked for an executable regular file")
    func absolutePaths() {
        #expect(ExecutableResolver.resolve("/bin/ls", path: "", shell: "/bin/sh") == "/bin/ls")
        #expect(ExecutableResolver.resolve("/bin/../bin/ls", path: "", shell: "/bin/sh") == "/bin/ls")
        #expect(ExecutableResolver.resolve("/nonexistent/tool", path: "", shell: "/bin/sh") == nil)
        // A directory passes access(X_OK) but cannot be exec'd.
        #expect(ExecutableResolver.resolve("/usr/bin", path: "", shell: "/bin/sh") == nil)
        #expect(ExecutableResolver.resolve("/etc/hosts", path: "", shell: "/bin/sh") == nil)
    }

    @Test("~ expands against the given home directory")
    func tildeExpansion() throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        let tool = try fixture.file("home/bin/tool")

        #expect(ExecutableResolver.resolve("~/bin/tool", path: "", shell: "/bin/sh", homeDirectory: fixture.home) == tool)
        #expect(ExecutableResolver.resolve("~/bin/missing", path: "", shell: "/bin/sh", homeDirectory: fixture.home) == nil)
        #expect(ExecutableResolver.resolve("~", path: "", shell: "/bin/sh", homeDirectory: fixture.home) == nil)
    }

    @Test("bare names take the first PATH hit that is an executable file")
    func bareNames() throws {
        let fixture = try ResolverFixture()
        defer { fixture.remove() }
        try fixture.file("a/claude", executable: false)   // not executable: skipped
        let claude = try fixture.file("b/claude")
        let codex = try fixture.file("a/codex")
        try fixture.file("b/codex")

        #expect(ExecutableResolver.resolve("claude", path: fixture.path, shell: "/bin/sh") == claude)
        #expect(ExecutableResolver.resolve("codex", path: fixture.path, shell: "/bin/sh") == codex)
        #expect(ExecutableResolver.resolve("cursor-agent", path: fixture.path, shell: "/bin/sh") == nil)
        #expect(ExecutableResolver.resolve("claude", path: "", shell: "/bin/sh") == nil)
        // Empty PATH segments are skipped, surrounding whitespace in the command is ignored.
        #expect(ExecutableResolver.resolve(" claude ", path: "::\(fixture.path)::", shell: "/bin/sh") == claude)
        #expect(ExecutableResolver.resolve("", path: fixture.path, shell: "/bin/sh") == nil)
    }

    @Test("isExecutableFile")
    func isExecutableFile() {
        #expect(ExecutableResolver.isExecutableFile("/bin/sh"))
        #expect(!ExecutableResolver.isExecutableFile("/bin"))
        #expect(!ExecutableResolver.isExecutableFile("/nonexistent"))
    }
}
