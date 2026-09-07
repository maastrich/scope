import CoreServices
import Foundation
import Testing
@testable import ScopeCore

@Suite struct ScopeEventFilterTests {
    private let root = URL(fileURLWithPath: "/Users/me/src/acme", isDirectory: true)

    private func flags(_ values: Int...) -> FSEventStreamEventFlags {
        values.reduce(0) { $0 | FSEventStreamEventFlags($1) }
    }

    private func event(_ relativePath: String, _ flagValues: Int..., id: FSEventStreamEventId = 1) -> FSEventBatch.Event {
        let path = relativePath.isEmpty ? root.path : root.path + "/" + relativePath
        return FSEventBatch.Event(path: path, flags: flagValues.reduce(0) { $0 | FSEventStreamEventFlags($1) }, id: id)
    }

    private func classify(_ events: [FSEventBatch.Event], depth: Int = 1, known: Set<String> = ["api"]) -> ScopeChangeHint {
        ScopeEventFilter.classify(FSEventBatch(events: events), root: root, depth: depth, knownRepos: known)
    }

    // MARK: Noise

    @Test(arguments: [
        "api/.git/objects/ab/cdef0123",
        "api/.git/objects/pack/pack-1.idx",
        "api/.git/logs/HEAD",
        "api/.git/logs/refs/heads/main",
        "api/.git/index.lock",
        "api/.git/refs/heads/main.lock",
        "api/README.md.sb-6625059b-F0H2sp",
        "api/src/main.swift~",
        "api/src/.#main.swift",
        "api/.DS_Store",
        ".DS_Store",
    ])
    func ignoredPathsProduceNoHint(path: String) {
        let hint = classify([event(path, kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)])
        #expect(hint == .none)
        #expect(hint.isEmpty)
    }

    @Test func eventsOutsideTheRootAreIgnored() {
        let outside = FSEventBatch.Event(path: "/Users/me/src/other/x.txt",
                                         flags: flags(kFSEventStreamEventFlagItemCreated), id: 1)
        let sibling = FSEventBatch.Event(path: "/Users/me/src/acme-2/api/x.txt",
                                         flags: flags(kFSEventStreamEventFlagItemCreated), id: 2)
        #expect(classify([outside, sibling]) == .none)
    }

    // MARK: Touched repos

    @Test func fileChangeInsideAKnownRepoTouchesIt() {
        let hint = classify([event("api/src/main.swift", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)])
        #expect(hint == ScopeChangeHint(touchedRepos: ["api"]))
    }

    @Test func gitMetadataOutsideObjectsAndLogsTouchesTheRepo() {
        let hint = classify([
            event("api/.git/HEAD", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified),
            event("api/.git/index", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified),
            event("api/.git/refs/heads/main", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated),
        ])
        #expect(hint == ScopeChangeHint(touchedRepos: ["api"]))
    }

    @Test func changesOutsideAnyKnownRepoTouchNothing() {
        let hint = classify([event("docs/notes.md", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)],
                            known: ["api", "web"])
        #expect(hint == .none)
    }

    @Test func repoNameIsMatchedByComponentNotByPrefix() {
        let hint = classify([event("api-wt/x.txt", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)],
                            known: ["api"])
        #expect(hint == .none)
    }

    @Test func repoScopeRootIsTouchedByAnyChangeIncludingTheRootItself() {
        let inside = classify([event("src/x.swift", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)],
                              known: [""])
        #expect(inside == ScopeChangeHint(touchedRepos: [""]))

        let rootOnly = classify([event("", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemModified)], known: [""])
        #expect(rootOnly == ScopeChangeHint(touchedRepos: [""]))

        let plainRoot = classify([event("", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemModified)], known: [])
        #expect(plainRoot == .none)
    }

    @Test func nestedKnownReposAreAllTouched() {
        let hint = classify([event("vendor/lib/src/y.c", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)],
                            depth: 2, known: ["", "vendor/lib", "other"])
        #expect(hint.touchedRepos == ["", "vendor/lib"])
        #expect(!hint.needsRescan)
    }

    // MARK: Rescans

    @Test func folderCreatedWithinDepthTriggersRescan() {
        let hint = classify([event("newrepo", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)])
        #expect(hint == ScopeChangeHint(rescan: true))
    }

    @Test func folderRemovedOrRenamedWithinDepthTriggersRescan() {
        #expect(classify([event("api", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemRemoved)]).rescan)
        #expect(classify([event("api", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemRenamed)]).rescan)
    }

    @Test func folderCreatedDeeperThanDepthOnlyTouches() {
        let hint = classify([event("api/src/newdir", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)])
        #expect(hint == ScopeChangeHint(touchedRepos: ["api"]))

        let deeper = classify([event("deep/nested", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)], depth: 1)
        #expect(deeper == .none)
        let inRange = classify([event("deep/nested", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)], depth: 2)
        #expect(inRange == ScopeChangeHint(rescan: true))
    }

    @Test func folderModifiedWithoutStructuralChangeDoesNotRescan() {
        let hint = classify([event("api", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemModified)])
        #expect(hint == ScopeChangeHint(touchedRepos: ["api"]))
    }

    @Test func hiddenFoldersNeverTriggerRescan() {
        #expect(classify([event(".vscode", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)]) == .none)
        #expect(classify([event(".hidden/repo/.git", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)], depth: 3) == .none)
        let hiddenInsideRepo = classify([event("api/.github/workflows", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)], depth: 3)
        #expect(hiddenInsideRepo == ScopeChangeHint(touchedRepos: ["api"]))
    }

    @Test func gitAppearingOrVanishingTriggersRescan() {
        let created = classify([event("newrepo/.git", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)])
        #expect(created == ScopeChangeHint(rescan: true))

        let removed = classify([event("api/.git", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemRemoved)])
        #expect(removed.rescan)
        #expect(removed.touchedRepos == ["api"])

        let worktreeFile = classify([event("wt/.git", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated)])
        #expect(worktreeFile == ScopeChangeHint(rescan: true))

        let rootBecameRepo = classify([event(".git", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)], depth: 0, known: [])
        #expect(rootBecameRepo == ScopeChangeHint(rescan: true))
    }

    @Test func gitBeyondDiscoveryDepthDoesNotRescan() {
        let hint = classify([event("deep/nested/.git", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)], depth: 1)
        #expect(hint == .none)
    }

    @Test func gitFolderModifiedOnlyTouches() {
        let hint = classify([event("api/.git", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemModified)])
        #expect(hint == ScopeChangeHint(touchedRepos: ["api"]))
    }

    // MARK: Full rescans

    @Test func mustScanSubDirsAsksForAFullRescan() {
        let hint = classify([event("", kFSEventStreamEventFlagMustScanSubDirs)])
        #expect(hint.fullRescan)
        #expect(!hint.rootChanged)
        #expect(hint.needsRescan)
    }

    @Test func rootChangedIsReportedAndImpliesFullRescan() {
        let hint = classify([event("", kFSEventStreamEventFlagRootChanged)], known: [""])
        #expect(hint.fullRescan)
        #expect(hint.rootChanged)
        #expect(hint.touchedRepos.isEmpty)
    }

    // MARK: Path reconciliation

    @Test func privatePrefixedPathsMatchADeclaredTmpRoot() {
        let tmpRoot = URL(fileURLWithPath: "/tmp/scope-acme", isDirectory: true)
        let created = FSEventBatch.Event(path: "/private/tmp/scope-acme/newrepo",
                                         flags: flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated), id: 1)
        let touched = FSEventBatch.Event(path: "/private/tmp/scope-acme/api/x.txt",
                                         flags: flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified), id: 2)
        let hint = ScopeEventFilter.classify(FSEventBatch(events: [created, touched]), root: tmpRoot, depth: 1, knownRepos: ["api"])
        #expect(hint == ScopeChangeHint(rescan: true, touchedRepos: ["api"]))
    }

    @Test func trailingSlashOnTheRootIsHarmless() {
        let slashed = URL(fileURLWithPath: "/Users/me/src/acme/", isDirectory: true)
        let hint = ScopeEventFilter.classify(FSEventBatch(events: [event("newrepo", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)]),
                                             root: slashed, depth: 1, knownRepos: [])
        #expect(hint == ScopeChangeHint(rescan: true))
    }

    // MARK: Batches and merging

    @Test func aBatchAccumulatesAcrossEvents() {
        let hint = classify([
            event("api/src/a.swift", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified),
            event("web/src/b.ts", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated),
            event("newrepo", kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated),
            event("api/.git/objects/12/34", kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated),
        ], known: ["api", "web"])
        #expect(hint == ScopeChangeHint(rescan: true, touchedRepos: ["api", "web"]))
    }

    @Test func mergedUnionsFlagsAndRepos() {
        let a = ScopeChangeHint(rescan: true, touchedRepos: ["api"])
        let b = ScopeChangeHint(fullRescan: true, rootChanged: true, touchedRepos: ["web"])
        let merged = a.merged(with: b)
        #expect(merged == ScopeChangeHint(rescan: true, fullRescan: true, rootChanged: true, touchedRepos: ["api", "web"]))
        #expect(a.merged(with: .none) == a)
        #expect(ScopeChangeHint.none.merged(with: .none) == .none)
        #expect(ScopeChangeHint.none.isEmpty)
        #expect(!ScopeChangeHint.none.needsRescan)
    }
}
