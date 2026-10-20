import Foundation
import Testing
@testable import ScopeCore

@Suite struct BrowserRouteTests {
    private let block = PortBlock(base: 41_000)

    private func route(_ link: String, _ preference: WebLinkDestination = .localhost, hasTask: Bool = true,
                       alternate: Bool = false) -> BrowserRoute.Destination {
        BrowserRoute.destination(for: URL(string: link)!, block: block, preference: preference, hasTask: hasTask,
                                 alternate: alternate)
    }

    @Test func aPortOfTheBlockOpensInThePaneUnderEveryPreferenceButNone() {
        for preference in [WebLinkDestination.taskServers, .localhost, .everything] {
            #expect(route("http://localhost:41003/checkout", preference) == .pane)
            #expect(route("http://127.0.0.1:41000", preference) == .pane)
        }
        #expect(route("http://localhost:41003", .systemBrowser) == .system)
    }

    @Test func anotherLocalhostFollowsThePreference() {
        #expect(route("http://localhost:5173", .taskServers) == .system)
        #expect(route("http://localhost:5173", .localhost) == .pane)
        #expect(route("http://[::1]:3000", .localhost) == .pane)
        #expect(route("http://app.localhost:3000", .localhost) == .pane)
        #expect(route("http://localhost:5173", .everything) == .pane)
    }

    @Test func theWebGoesToTheSystemUnlessAskedOtherwise() {
        #expect(route("https://github.com/maastrich/scope/pull/91") == .system)
        #expect(route("https://github.com/maastrich/scope/pull/91", .taskServers) == .system)
        #expect(route("https://github.com/maastrich/scope/pull/91", .everything) == .pane)
    }

    @Test func optionSendsTheLinkToTheOtherDestination() {
        #expect(route("http://localhost:41000", alternate: true) == .system)
        #expect(route("https://example.com", alternate: true) == .pane)
        #expect(route("http://localhost:41000", .systemBrowser, alternate: true) == .pane)
    }

    @Test func withoutATaskOrOutsideTheWebItIsAlwaysTheSystem() {
        #expect(route("http://localhost:41000", hasTask: false) == .system)
        #expect(route("https://example.com", .everything, hasTask: false, alternate: true) == .system)
        #expect(route("mailto:someone@example.com", .everything) == .system)
        #expect(route("vscode://file/tmp/a.swift", .everything, alternate: true) == .system)
        #expect(route("file:///tmp/index.html", .everything) == .system)
    }

    @Test func aTaskWithoutABlockOnlyHasNoTaskServer() {
        let url = URL(string: "http://localhost:41000")!
        #expect(BrowserRoute.destination(for: url, block: nil, preference: .taskServers, hasTask: true) == .system)
        #expect(BrowserRoute.destination(for: url, block: nil, preference: .localhost, hasTask: true) == .pane)
    }

    @Test func everyLoopbackSpellingIsOneServer() {
        let a = URL(string: "http://localhost:41000/checkout")!
        #expect(BrowserRoute.sameServer(a, URL(string: "http://127.0.0.1:41000/")!))
        #expect(!BrowserRoute.sameServer(a, URL(string: "http://localhost:41001/")!))
        #expect(!BrowserRoute.sameServer(a, URL(string: "https://localhost:41000/")!))
        #expect(BrowserRoute.sameServer(URL(string: "https://example.com/a")!, URL(string: "https://EXAMPLE.com:443/b")!))
        #expect(!BrowserRoute.sameServer(URL(string: "https://example.com")!, URL(string: "https://example.org")!))
    }

    @Test func theAddressBarReadsPortsHostsAndURLs() {
        #expect(BrowserRoute.url(fromAddress: ":41000")?.absoluteString == "http://localhost:41000")
        #expect(BrowserRoute.url(fromAddress: "41000")?.absoluteString == "http://localhost:41000")
        #expect(BrowserRoute.url(fromAddress: "localhost:5173/a")?.absoluteString == "http://localhost:5173/a")
        #expect(BrowserRoute.url(fromAddress: "example.com/docs")?.absoluteString == "https://example.com/docs")
        #expect(BrowserRoute.url(fromAddress: " http://localhost:41000/x ")?.absoluteString == "http://localhost:41000/x")
        #expect(BrowserRoute.url(fromAddress: "two words") == nil)
        #expect(BrowserRoute.url(fromAddress: "nodot") == nil)
        #expect(BrowserRoute.url(fromAddress: "") == nil)
    }

    @Test func aTabTitleBeforeThePageNamesItself() {
        #expect(BrowserRoute.shortTitle(URL(string: "http://localhost:41000/checkout")!) == ":41000")
        #expect(BrowserRoute.shortTitle(URL(string: "https://example.com/a")!) == "example.com")
    }

    @Test func storesAreStablePerHomeAndApartPerScopeHomeAndRole() {
        let home = URL(fileURLWithPath: "/Users/me/.scope-debug")
        let user = BrowserStoreID.user(home: home, scope: "maastrich")
        #expect(user == BrowserStoreID.user(home: URL(fileURLWithPath: "/Users/me/.scope-debug/"), scope: "maastrich"))
        #expect(user != BrowserStoreID.user(home: URL(fileURLWithPath: "/tmp/scope-demo/home"), scope: "maastrich"))
        #expect(user != BrowserStoreID.user(home: home, scope: "other"))
        #expect(user != BrowserStoreID.agent(home: home, task: "maastrich"))
        // A version 5, RFC 4122 variant UUID.
        #expect(user.uuidString.dropFirst(14).first == "5")
        #expect("89AB".contains(user.uuidString.dropFirst(19).first!))
    }

    @Test func aLinkReusesTheTabOfItsServer() {
        var tabs = BrowserTabs()
        tabs.open("a", in: "t1", url: URL(string: "http://localhost:41000/")!)
        tabs.open("b", in: "t1", url: URL(string: "http://localhost:41001/")!)
        tabs.open("c", in: "t2", url: URL(string: "http://localhost:41000/")!)
        #expect(tabs.tab(of: "t1", serving: URL(string: "http://127.0.0.1:41000/checkout")!)?.id == "a")
        #expect(tabs.tab(of: "t1", serving: URL(string: "http://localhost:41002/")!) == nil)
        #expect(tabs.selectedTab(of: "t1")?.id == "b")
        tabs.update("b", url: URL(string: "http://localhost:41000/other")!)
        // Two tabs on one server: the shown one takes the link.
        #expect(tabs.tab(of: "t1", serving: URL(string: "http://localhost:41000/")!)?.id == "b")
    }

    @Test func closingATabShowsItsRightNeighbourThenItsLeft() {
        var tabs = BrowserTabs()
        tabs.open("a", in: "t", url: nil)
        tabs.open("b", in: "t", url: nil)
        tabs.open("c", in: "t", url: nil)
        tabs.select("b")
        tabs.close("b")
        #expect(tabs.selectedTab(of: "t")?.id == "c")
        tabs.close("c")
        #expect(tabs.selectedTab(of: "t")?.id == "a")
        #expect(tabs.closeAll(of: "t").map(\.id) == ["a"])
        #expect(tabs.tabs.isEmpty)
    }
}
