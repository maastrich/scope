import Foundation
import Testing
@testable import ScopeCore

@Suite("ScopeHome")
struct ScopeHomeTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test("a Debug build ignores a SCOPE_HOME it inherited from a thread")
    func debugIgnoresInheritedHome() {
        let env = ["SCOPE_HOME": "/Users/someone/.scope", "SCOPE_THREAD": "8a18d7476063"]
        let url = ScopeHome.appURL(environment: env, debugBuild: true)
        #expect(url == home.appending(path: ".scope-debug", directoryHint: .isDirectory))
    }

    @Test("a Debug build still obeys a SCOPE_HOME set by hand")
    func debugObeysDeliberateHome() {
        let env = ["SCOPE_HOME": "/tmp/scope-demo"]
        let url = ScopeHome.appURL(environment: env, debugBuild: true)
        #expect(url.path == "/tmp/scope-demo")
    }

    @Test("a Debug build with no override lands in .scope-debug")
    func debugDefault() {
        let url = ScopeHome.appURL(environment: [:], debugBuild: true)
        #expect(url == home.appending(path: ".scope-debug", directoryHint: .isDirectory))
    }

    @Test("a release build honours SCOPE_HOME however it arrived")
    func releaseHonoursInheritedHome() {
        let env = ["SCOPE_HOME": "/tmp/scope-prod", "SCOPE_THREAD": "8a18d7476063"]
        let url = ScopeHome.appURL(environment: env, debugBuild: false)
        #expect(url.path == "/tmp/scope-prod")
    }

    @Test("a release build with no override lands in .scope")
    func releaseDefault() {
        let url = ScopeHome.appURL(environment: [:], debugBuild: false)
        #expect(url == home.appending(path: ".scope", directoryHint: .isDirectory))
    }

    @Test("UI state lives under the home, so two builds never share one file")
    func uiStateFollowsTheHome() {
        let release = ScopeHome.url(environment: [:])
        let debug = ScopeHome.appURL(environment: [:], debugBuild: true)
        #expect(ScopeHome.uiStateURL(home: release).path == release.path + "/ui-state.json")
        #expect(ScopeHome.uiStateURL(home: debug).path == debug.path + "/ui-state.json")
        #expect(ScopeHome.uiStateURL(home: release) != ScopeHome.uiStateURL(home: debug))
    }

    @Test("every path the app writes derives from the home it was given")
    func everythingFollowsTheHome() {
        let home = URL(fileURLWithPath: "/tmp/scope-a", isDirectory: true)
        let paths = [ScopeHome.configURL(home: home), ScopeHome.driversURL(home: home), ScopeHome.graphURL(home: home),
                     ScopeHome.threadsURL(home: home), ScopeHome.sandboxesURL(home: home),
                     ScopeHome.spotlightMarkerURL(home: home), ScopeHome.uiStateURL(home: home),
                     ScopeHome.releasesURL(home: home)]
        for path in paths { #expect(path.path.hasPrefix("/tmp/scope-a/"), "\(path.path)") }
    }
}
