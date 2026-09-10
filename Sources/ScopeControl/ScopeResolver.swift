import Foundation

/// Turns what a caller wrote — or did not write — into one scope.
///
/// Pure, and deliberately generous: an agent will say `acme`, a person will paste a path, and a script will
/// hold an id. When nothing is said the caller's own scope wins, then the scope holding its working
/// directory, then the only scope there is; anything else is an error that lists the choices instead of
/// picking one.
public enum ScopeResolver {
    /// Resolves `query` against `scopes`.
    /// - Parameters:
    ///   - callerScopeID: the scope of the thread the request came from, when it came from one.
    ///   - callerCwd: the client's working directory.
    public static func resolve(_ query: String?, in scopes: [ScopeSummary],
                               callerScopeID: String? = nil, callerCwd: String? = nil) -> Result<ScopeSummary, ControlError> {
        guard !scopes.isEmpty else {
            return .failure(.notFound("Scope has no scope declared", detail: "Add a folder in the app first."))
        }
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            if let callerScopeID, let own = scopes.first(where: { $0.id == callerScopeID }) {
                return .success(own)
            }
            if let callerCwd, let holding = scopeHolding(callerCwd, in: scopes) {
                return .success(holding)
            }
            if scopes.count == 1 { return .success(scopes[0]) }
            return .failure(.badRequest("which scope?", detail: choices(scopes)))
        }

        let lowered = query.lowercased()
        if let byID = scopes.first(where: { $0.id.lowercased() == lowered }) { return .success(byID) }
        if let bySlug = scopes.first(where: { $0.slug.lowercased() == lowered }) { return .success(bySlug) }

        let byName = scopes.filter { $0.name.lowercased() == lowered }
        if byName.count == 1 { return .success(byName[0]) }
        if byName.count > 1 {
            return .failure(.badRequest("“\(query)” names \(byName.count) scopes", detail: choices(byName)))
        }

        if query.hasPrefix("/") || query.hasPrefix("~") || query.hasPrefix(".") {
            let path = normalize((query as NSString).expandingTildeInPath)
            if let byPath = scopes.first(where: { normalize($0.path) == path }) { return .success(byPath) }
            if let holding = scopeHolding(path, in: scopes) { return .success(holding) }
        }
        return .failure(.notFound("no scope called “\(query)”", detail: choices(scopes)))
    }

    /// The declared scope whose root contains `path`, deepest first (nested scopes exist).
    public static func scopeHolding(_ path: String, in scopes: [ScopeSummary]) -> ScopeSummary? {
        let target = normalize(path)
        return scopes
            .filter { target == normalize($0.path) || target.hasPrefix(normalize($0.path) + "/") }
            .max { normalize($0.path).count < normalize($1.path).count }
    }

    /// Matches `query` against the repositories of `scope`: exact relative path first, then a unique suffix
    /// (`api` finds `services/api`), then the basename.
    public static func resolveRepo(_ query: String, in scope: ScopeSummary) -> Result<String, ControlError> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !needle.isEmpty else { return .success(".") }
        if needle == "." || scope.repos.contains(needle) { return .success(needle) }
        let matches = scope.repos.filter { $0 == needle || $0.hasSuffix("/" + needle) }
        if matches.count == 1 { return .success(matches[0]) }
        if matches.count > 1 {
            return .failure(.badRequest("“\(query)” matches \(matches.count) repositories in \(scope.slug)",
                                        detail: matches.joined(separator: "\n")))
        }
        return .failure(.notFound("no repository “\(query)” in \(scope.slug)",
                                  detail: scope.repos.isEmpty ? "That scope holds no repository." : scope.repos.joined(separator: "\n")))
    }

    static func choices(_ scopes: [ScopeSummary]) -> String {
        "Name one with --scope:\n" + scopes.map { "  \($0.slug)  \($0.path)" }.joined(separator: "\n")
    }

    /// Trailing slashes off, symlinks left alone (the app stores what the user declared).
    static func normalize(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
