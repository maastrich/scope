import Foundation
import Testing
@testable import ScopeControl
import ScopeAdapters
import ScopeCore

/// The home an app build starts on: debug/release × inherited/deliberate/absent, and the guard that keeps a
/// Debug build off `~/.scope` whichever way it was sent there.
///
/// Every case passes its own environment: the test process may itself run inside a Scope thread and carry the
/// very variables under test.
@Suite("AppHome")
struct AppHomeTests {
    private static let userHome = FileManager.default.homeDirectoryForCurrentUser
    private static let production = userHome.appending(path: ".scope", directoryHint: .isDirectory)
    private static let debug = userHome.appending(path: ".scope-debug", directoryHint: .isDirectory)

    /// What Scope injects into a thread of an app running on `home`.
    private static func thread(of home: URL) -> [String: String] {
        ["SCOPE_HOME": home.path, "SCOPE_SOCK": SocketPath.resolve(home: home), "SCOPE_THREAD": "8a18d7476063",
         "SCOPE_PORT": "41020", "SCOPE_TASK": "demo", "SCOPE_SCOPE": "acme"]
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var name: String
        var environment: [String: String]
        var debugBuild: Bool
        var expected: AppHome.Resolution
        var testDescription: String { name }
    }

    static let matrix: [Row] = [
        Row(name: "debug, absent", environment: [:], debugBuild: true,
            expected: .init(home: debug)),
        Row(name: "debug, inherited from a production thread", environment: thread(of: production), debugBuild: true,
            expected: .init(home: debug, ignoredInherited: production.path)),
        Row(name: "debug, inherited from a thread of a custom home",
            environment: thread(of: URL(fileURLWithPath: "/tmp/scope-custom", isDirectory: true)), debugBuild: true,
            expected: .init(home: debug, ignoredInherited: "/tmp/scope-custom")),
        Row(name: "debug, inherited with the socket stripped",
            environment: ["SCOPE_HOME": production.path, "SCOPE_THREAD": "8a18d7476063"], debugBuild: true,
            expected: .init(home: debug, ignoredInherited: production.path)),
        Row(name: "debug, deliberate from a plain terminal", environment: ["SCOPE_HOME": "/tmp/scope-demo"], debugBuild: true,
            expected: .init(home: URL(fileURLWithPath: "/tmp/scope-demo", isDirectory: true))),
        Row(name: "debug, deliberate from inside a thread",
            environment: thread(of: production).merging(["SCOPE_HOME": "/tmp/scope-demo"]) { $1 }, debugBuild: true,
            expected: .init(home: URL(fileURLWithPath: "/tmp/scope-demo", isDirectory: true))),
        Row(name: "debug, deliberately the production home", environment: ["SCOPE_HOME": production.path], debugBuild: true,
            expected: .init(home: debug, refusedProduction: production.path)),
        Row(name: "debug, the production home with the thread id stripped",
            environment: thread(of: production).filter { $0.key != "SCOPE_THREAD" }, debugBuild: true,
            expected: .init(home: debug, refusedProduction: production.path)),
        Row(name: "debug, the production home spelled with a tilde", environment: ["SCOPE_HOME": "~/.scope/"], debugBuild: true,
            expected: .init(home: debug, refusedProduction: production.path)),
        Row(name: "release, absent", environment: [:], debugBuild: false,
            expected: .init(home: production)),
        Row(name: "release, inherited", environment: thread(of: URL(fileURLWithPath: "/tmp/scope-prod", isDirectory: true)),
            debugBuild: false, expected: .init(home: URL(fileURLWithPath: "/tmp/scope-prod", isDirectory: true))),
        Row(name: "release, deliberate", environment: ["SCOPE_HOME": "/tmp/scope-prod"], debugBuild: false,
            expected: .init(home: URL(fileURLWithPath: "/tmp/scope-prod", isDirectory: true))),
    ]

    @Test(arguments: matrix)
    func resolution(_ row: Row) {
        let resolved = AppHome.resolve(environment: row.environment, debugBuild: row.debugBuild)
        #expect(resolved.home.standardizedFileURL.path == row.expected.home.standardizedFileURL.path)
        #expect(resolved.ignoredInherited == row.expected.ignoredInherited)
        #expect(resolved.refusedProduction == row.expected.refusedProduction)
    }

    @Test("no row of the matrix lets a Debug build onto the production home")
    func debugNeverLandsOnProduction() {
        for row in Self.matrix where row.debugBuild {
            #expect(!AppHome.isProductionHome(AppHome.resolve(environment: row.environment, debugBuild: true).home),
                    "\(row.name)")
        }
    }

    @Test("a Debug build and a Release build started from the same thread listen on different sockets")
    func socketsDiffer() {
        let environment = Self.thread(of: Self.production)
        let debugSocket = SocketPath.resolve(home: AppHome.resolve(environment: environment, debugBuild: true).home)
        let releaseSocket = SocketPath.resolve(home: AppHome.resolve(environment: environment, debugBuild: false).home)
        #expect(debugSocket != releaseSocket)
        #expect(debugSocket != environment["SCOPE_SOCK"])
        #expect(releaseSocket == environment["SCOPE_SOCK"])
    }

    @Test("the production home is recognised through a symlink and another case")
    func productionHomeSpellings() throws {
        #expect(AppHome.isProductionHome(Self.production))
        #expect(AppHome.isProductionHome(URL(fileURLWithPath: Self.production.path.uppercased())))
        #expect(!AppHome.isProductionHome(Self.debug))

        let link = FileManager.default.temporaryDirectory.appending(path: "scope-home-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.production)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(AppHome.isProductionHome(link))
        #expect(AppHome.resolve(environment: ["SCOPE_HOME": link.path], debugBuild: true).refusedProduction != nil)
    }

    @Test("a link to a home that does not exist yet is still that home")
    func danglingLink() throws {
        // `~/.scope` is missing on a machine where the installed app never ran, CI included.
        let directory = FileManager.default.temporaryDirectory.appending(path: "scope-dangling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "home")
        let link = directory.appending(path: "link")
        let relative = directory.appending(path: "relative")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        try FileManager.default.createSymbolicLink(atPath: relative.path, withDestinationPath: "home")

        #expect(AppHome.canonical(link) == AppHome.canonical(missing))
        #expect(AppHome.canonical(relative) == AppHome.canonical(missing))
    }

    @Test("both refusals are reported, the production one as an error naming the home")
    func problems() {
        let refused = AppHome.resolve(environment: ["SCOPE_HOME": Self.production.path], debugBuild: true).problems
        #expect(refused.count == 1)
        #expect(refused.first?.severity == .error)
        #expect(refused.first?.detail?.contains(Self.production.path) == true)

        let ignored = AppHome.resolve(environment: Self.thread(of: Self.production), debugBuild: true).problems
        #expect(ignored.map(\.severity) == [.info])
        #expect(AppHome.resolve(environment: [:], debugBuild: true).problems.isEmpty)
        #expect(AppHome.resolve(environment: Self.thread(of: Self.production), debugBuild: false).problems.isEmpty)
    }
}
