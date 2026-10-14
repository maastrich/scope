import Foundation
import Testing
import ScopeCore
@testable import ScopeDrivers
@testable import ScopeTasks

@Suite struct EditorTargetTests {
    private let folder = EditorTarget(folder: "/s/api")
    private let file = EditorTarget(folder: "/s/api", file: "src/a.swift", line: 12)
    private let task = EditorTarget(taskRoot: "/s", sandboxes: ["/s/api", "/s/web"], workspace: "/s/auth.code-workspace")

    @Test func aStoredTemplateStillNamesItsEditor() {
        // What a config written before per-editor launching holds.
        #expect(KnownEditor(template: EditorTemplate(argv: ["zed", "{file}:{line}"])) == .zed)
        #expect(KnownEditor(template: EditorTemplate(argv: ["code", "-g", "{file}:{line}"])) == .vscode)
        #expect(KnownEditor(template: EditorTemplate(argv: ["zed", "-n", "{path}"])) == nil)
    }

    @Test func zedReusesItsWindowAndNeverGetsTheWorkspaceFile() {
        let zed = KnownEditor.zed.template
        #expect(zed.argv(for: folder) == ["zed", "-e", "/s/api"])
        #expect(zed.argv(for: file) == ["zed", "-e", "/s/api", "/s/api/src/a.swift:12"])
        #expect(zed.argv(for: task) == ["zed", "-e", "/s/api", "/s/web"])
    }

    @Test func codeOpensTheWorkspaceOnlyForSeveralSandboxes() {
        let code = KnownEditor.vscode.template
        #expect(code.argv(for: folder) == ["code", "/s/api"])
        #expect(code.argv(for: file) == ["code", "/s/api", "-g", "/s/api/src/a.swift:12"])
        #expect(code.argv(for: task) == ["code", "/s/auth.code-workspace"])
        let single = EditorTarget(taskRoot: "/s/api", sandboxes: ["/s/api"], workspace: "/s/auth.code-workspace")
        #expect(KnownEditor.cursor.template.argv(for: single) == ["cursor", "/s/api"])
        let unwritten = EditorTarget(taskRoot: "/s", sandboxes: ["/s/api", "/s/web"], workspace: nil)
        #expect(code.argv(for: unwritten) == ["code", "/s/api", "/s/web"])
    }

    @Test func theOthersGetTheTaskRoot() {
        #expect(KnownEditor.jetbrains.template.argv(for: task) == ["idea", "/s"])
        #expect(KnownEditor.jetbrains.template.argv(for: file) == ["idea", "/s/api", "--line", "12", "/s/api/src/a.swift"])
        #expect(KnownEditor.nova.template.argv(for: folder) == ["nova", "/s/api"])
        #expect(KnownEditor.sublime.template.argv(for: task) == ["subl", "/s/api", "/s/web"])
        #expect(KnownEditor.sublime.template.argv(for: EditorTarget(folder: "/s/api", file: "/s/api/a.swift")) == ["subl", "/s/api/a.swift"])
    }

    @Test func aCustomCommandIsExpandedOnTheRoot() {
        let custom = EditorTemplate(argv: ["open", "-a", "Xcode", "{path}"])
        #expect(custom.argv(for: task) == ["open", "-a", "Xcode", "/s"])
        #expect(custom.argv(for: file) == ["open", "-a", "Xcode", "/s/api", "/s/api/src/a.swift"])
    }

    @Test func aThreadInASubfolderNamesItsSandbox() {
        let record = TaskRecord(
            scopeID: ScopeID(rawValue: "8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"), scopeRoot: "/s/acme", scopeSlug: "acme", scopeName: "Acme",
            name: "Auth", slug: "auth", branch: "scope/auth", root: "/h/auth",
            repos: [TaskRepo(repoRelativePath: "api", sandboxPath: "/h/auth/api", branch: "scope/auth"),
                    TaskRepo(repoRelativePath: "api-client", sandboxPath: "/h/auth/api-client", branch: "scope/auth")],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(record.sandbox(containing: "/h/auth/api/src/routes")?.repoRelativePath == "api")
        #expect(record.sandbox(containing: "/h/auth/api-client")?.repoRelativePath == "api-client")
        #expect(record.sandbox(containing: "/h/auth") == nil)
        #expect(record.sandbox(containing: "/elsewhere") == nil)
    }
}
