import Foundation
import ScopeCore

/// Rebinds persisted thread records to the scopes declared now.
///
/// A record names its scope by id and by root path. When the id is gone but a declared scope has the
/// same real path (the folder was removed and declared again), the record is rebound to the new id.
/// Anything else is an orphan: kept on disk, not shown.
enum ThreadRestorer {
    struct Result: Sendable {
        /// Records to show, in their original order; rebound ones carry the new `scopeID`.
        var restored: [ThreadRecord] = []
        /// Records whose `scopeID` changed (persist them).
        var rebound: [ThreadRecord] = []
        /// Records with no declared scope.
        var orphans: [ThreadRecord] = []
    }

    static func restore(_ records: [ThreadRecord], scopes: [ScopeDeclaration]) -> Result {
        var result = Result()
        let byID = Dictionary(scopes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byPath = Dictionary(scopes.map { (ScopeDeclaration.canonicalPath($0.path), $0) }, uniquingKeysWith: { first, _ in first })

        for var record in records {
            record.lastState = record.lastState?.normalizedAfterRestart
            if byID[record.scopeID] != nil {
                result.restored.append(record)
                continue
            }
            if !record.scopeRoot.isEmpty, let match = byPath[ScopeDeclaration.canonicalPath(record.scopeRoot)] {
                record.scopeID = match.id
                result.restored.append(record)
                result.rebound.append(record)
                continue
            }
            result.orphans.append(record)
        }
        return result
    }
}
