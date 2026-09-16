import Foundation
import Testing
@testable import ScopeCore

@Suite("ShellEscaping")
struct ShellEscapingTests {
    @Test func plainPathStaysBare() {
        #expect(ShellEscaping.escaped("/Users/me/dev/scope-1.2/README.md") == "/Users/me/dev/scope-1.2/README.md")
    }

    @Test func spacesAndShellMetacharactersAreEscaped() {
        #expect(ShellEscaping.escaped("/tmp/my file") == "/tmp/my\\ file")
        #expect(ShellEscaping.escaped("/tmp/a'b\"c$d&e(f)g") == "/tmp/a\\'b\\\"c\\$d\\&e\\(f\\)g")
        #expect(ShellEscaping.escaped("~/x*y?z[1]") == "\\~/x\\*y\\?z\\[1\\]")
    }

    @Test func nonASCIIPassesThrough() {
        #expect(ShellEscaping.escaped("/Users/me/Documents/résumé.pdf") == "/Users/me/Documents/résumé.pdf")
    }

    @Test func dropJoinsWithSpacesAndEndsWithOne() {
        let urls = [URL(fileURLWithPath: "/tmp/a b"), URL(fileURLWithPath: "/tmp/c", isDirectory: true)]
        #expect(ShellEscaping.droppedPaths(urls) == "/tmp/a\\ b /tmp/c/ ")
    }
}
