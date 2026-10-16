import Foundation
import Testing
@testable import ScopeCore

/// What one line of the usage log holds, and the ids the app derives so that nothing private ends up in one.
@Suite struct UsageEventTests {
    static let at = Date(timeIntervalSince1970: 1_792_000_000.25)

    @Test func aLineIsSortedJSONWithAnISODateAndNoAbsentFields() throws {
        let event = UsageEvent(at: Self.at, kind: .click, id: "inspector.delta.refresh", source: .mouse)
        let line = String(decoding: try event.line(), as: UTF8.self)
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix(#"{"at":"2026-"#))
        #expect(line.contains(#""id":"inspector.delta.refresh","kind":"click","source":"mouse"}"#))
        #expect(!line.contains("scope"), "absent optionals are left out, not written as null")
    }

    @Test func aLineDecodesBackToTheSameEvent() throws {
        let event = UsageEvent(at: Self.at, kind: .view, id: "sheet.graph", source: .app,
                               scope: "8c1f…", context: "quit", duration: 12.5)
        #expect(UsageEvent.decode(line: try event.line()) == event)
        #expect(UsageEvent.decode(line: Data("{\"at\":".utf8)) == nil, "a line cut short by a crash is skipped")
    }

    @Test func theAreaIsTheFirstComponent() {
        #expect(UsageEvent.area(of: "sidebar.thread") == "sidebar")
        #expect(UsageEvent.area(of: "control.thread.new") == "control")
        #expect(UsageEvent.area(of: "lonely") == "lonely")
    }

    @Test func slugsKeepWordsAndDropEverythingElse() {
        #expect(UsageID.slug("New Thread…") == "new-thread")
        #expect(UsageID.slug("arrow.clockwise") == "arrow-clockwise")
        #expect(UsageID.slug("  Open  in  Editor ") == "open-in-editor")
        #expect(UsageID.slug("Écrire") == "crire", "non-ASCII letters split words rather than leak into ids")
        #expect(UsageID.join("inspector", nil, "", "delta") == "inspector.delta")
    }

    /// The palette's row ids hold repository ids, file paths, topics and record ids: none of that may be logged.
    @Test func paletteRowsAreLoggedWithoutTheirData() {
        #expect(UsageID.palette(itemID: "new-thread", section: "Actions", actionSection: true) == "command.new-thread")
        #expect(UsageID.palette(itemID: "add-repo-libs/api", section: "Actions", actionSection: true) == "command.add-repo")
        #expect(UsageID.palette(itemID: "editor-sandbox-api", section: "Actions", actionSection: true) == "command.editor-sandbox")
        #expect(UsageID.palette(itemID: "task-topic-secret-plan", section: "Actions", actionSection: true) == "command.task-topic")
        #expect(UsageID.palette(itemID: "task-archive", section: "Actions", actionSection: true) == "command.task-archive")
        #expect(UsageID.palette(itemID: "editor-task", section: "Actions", actionSection: true) == "command.editor-task")
        #expect(UsageID.palette(itemID: "restore-task", section: "Actions", actionSection: true) == "command.restore-task")
        #expect(UsageID.palette(itemID: "weird-9f2c", section: "Actions", actionSection: true) == "command.other")
        #expect(UsageID.palette(itemID: "file-/Users/me/acme/a.swift", section: "Files", actionSection: false) == "palette.files")
        #expect(UsageID.palette(itemID: "thread-1234", section: "Go to Thread", actionSection: false) == "palette.go-to-thread")
    }

    @Test func changedKeysNameTheKeysNotTheValues() {
        struct Prefs: Encodable {
            var fontSize = 13
            var theme = "brand"
            var editor: String?
            var nested = ["a": 1]
        }
        var after = Prefs()
        #expect(UsageID.changedKeys(Prefs(), after).isEmpty)
        after.fontSize = 14
        after.editor = "zed"
        after.nested["a"] = 2
        #expect(UsageID.changedKeys(Prefs(), after) == ["editor", "fontSize", "nested"])
    }

    @Test func theRegistryKeepsAnExplicitLabelOverADerivedOne() {
        var registry = UsageRegistry()
        let added = registry.merge([UsageElement(id: "thread.toolbar.stop", label: "Stop")])
        let derived = registry.merge([UsageElement(id: "thread.toolbar.stop", label: "thread.toolbar.stop")])
        let again = registry.merge([UsageElement(id: "thread.toolbar.stop", label: "Stop")])
        #expect(added)
        #expect(!derived)
        #expect(!again, "nothing new")
        #expect(registry.elements["thread.toolbar.stop"]?.label == "Stop")
        #expect(registry.elements["thread.toolbar.stop"]?.area == "thread")
    }
}
