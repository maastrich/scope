import Foundation

/// Checks a setup or test command against the files of the folder it runs in, before anything runs it.
///
/// The commands come from a guess — the quick analysis reading manifests, or a driver describing the repository —
/// and a wrong guess used to surface as a failed setup on every task of the repository: `uv sync` in a repository
/// whose `pyproject.toml` only configures ruff, `make install` where the Makefile has no such target. The check is
/// conservative: it only answers for tools it knows, and only when the file the tool needs is plainly not there.
public enum SetupCommandCheck {
    /// Why `command` cannot work in `folder`, or `nil` when nothing says so.
    ///
    /// The segments are read in order against the files as they are now, so the check stops at the first tool it
    /// does not know: `./configure && make install` or `git submodule update --init && cd vendor/x && npm i` may
    /// create what the next segment needs.
    public static func problem(_ command: String, in folder: URL) -> String? {
        var cwd = folder
        for segment in segments(of: command) {
            let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let tool = words.first else { continue }
            if tool == "cd" {
                guard words.count > 1 else { continue }
                let target = words[1]
                if target.contains("$") || target.hasPrefix("~") { return nil }   // not a path the check can follow
                let next = target.hasPrefix("/") ? URL(fileURLWithPath: target) : cwd.appending(path: target)
                guard isDirectory(next) else { return "there is no folder \(target)" }
                cwd = next
                continue
            }
            guard knownTools.contains(tool) else { return nil }
            if let problem = problem(tool: tool, arguments: Array(words.dropFirst()), in: cwd, root: folder) { return problem }
        }
        return nil
    }

    static let knownTools: Set<String> = ["npm", "pnpm", "yarn", "bun", "uv", "poetry", "pip", "pip3", "cargo", "go", "swift",
                                          "bundle", "composer", "make"]

    /// `a && b; c || d` → `[a, b, c, d]`. Quotes are not parsed: a command that needs them is past what the check
    /// reads, and a segment it cannot read passes.
    static func segments(of command: String) -> [String] {
        command.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func problem(tool: String, arguments: [String], in cwd: URL, root: URL) -> String? {
        let has: (String) -> Bool = { FileManager.default.fileExists(atPath: cwd.appending(path: $0).path) }
        // npm, go, cargo, swift look for their manifest in the parent folders too, up to the repository's root.
        let hasAbove: (String) -> Bool = { name in
            var folder = cwd.standardizedFileURL
            let top = root.standardizedFileURL.path
            while true {
                if FileManager.default.fileExists(atPath: folder.appending(path: name).path) { return true }
                guard folder.path.count > top.count, folder.path.hasPrefix(top) else { return false }
                folder = folder.deletingLastPathComponent()
            }
        }
        let sub = arguments.first { !$0.hasPrefix("-") }
        switch tool {
        case "npm", "pnpm", "yarn", "bun":
            // A bare `yarn` installs.
            guard sub.map({ ["install", "i", "ci", "test", "run", "add"].contains($0) }) ?? (tool == "yarn") else { return nil }
            return hasAbove("package.json") ? nil : "there is no package.json"
        case "uv":
            guard let sub, sub == "sync" || sub == "run" else { return nil }
            guard has("pyproject.toml") else { return "there is no pyproject.toml" }
            return pyproject(in: cwd).isProject ? nil : "pyproject.toml has no [project] table"
        case "poetry":
            guard has("pyproject.toml") else { return "there is no pyproject.toml" }
            let pyproject = pyproject(in: cwd)
            return pyproject.isPoetry || pyproject.isProject ? nil : "pyproject.toml declares no Poetry project"
        case "pip", "pip3":
            guard sub == "install" else { return nil }
            if let index = arguments.firstIndex(where: { $0 == "-r" || $0 == "--requirement" || $0 == "--requirements" }),
               index + 1 < arguments.count {
                return has(arguments[index + 1]) ? nil : "there is no \(arguments[index + 1])"
            }
            guard arguments.contains(".") else { return nil }
            if has("setup.py") || has("setup.cfg") { return nil }
            guard has("pyproject.toml") else { return "there is no pyproject.toml nor setup.py" }
            let pyproject = pyproject(in: cwd)
            return pyproject.isProject || pyproject.isPoetry || pyproject.hasBuildSystem ? nil
                : "pyproject.toml declares no installable project"
        case "cargo":
            return hasAbove("Cargo.toml") ? nil : "there is no Cargo.toml"
        case "go":
            guard let sub, ["build", "test", "mod", "run", "vet"].contains(sub) else { return nil }
            return hasAbove("go.mod") ? nil : "there is no go.mod"
        case "swift":
            guard let sub, ["build", "test", "run", "package"].contains(sub) else { return nil }
            return hasAbove("Package.swift") ? nil : "there is no Package.swift"
        case "bundle":
            return has("Gemfile") ? nil : "there is no Gemfile"
        case "composer":
            return has("composer.json") ? nil : "there is no composer.json"
        case "make":
            if arguments.contains(where: { $0 == "-C" || $0 == "-f" || $0.hasPrefix("--directory") || $0.hasPrefix("--file") }) { return nil }
            guard let name = ["GNUmakefile", "makefile", "Makefile"].first(where: has),
                  let text = try? String(contentsOf: cwd.appending(path: name), encoding: .utf8) else {
                return "there is no Makefile"
            }
            guard let target = arguments.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) else { return nil }
            // An included makefile or a pattern rule can define the target where this cannot see it.
            if text.contains("include ") || text.contains("%:") { return nil }
            return makeTargets(text).contains(target) ? nil : "the Makefile has no \(target) target"
        default:
            return nil
        }
    }

    /// What `pyproject.toml` declares, from its table headers.
    public struct PyProject: Sendable, Equatable {
        public var isProject = false
        public var isPoetry = false
        public var hasBuildSystem = false
    }

    static func pyproject(in folder: URL) -> PyProject {
        guard let text = try? String(contentsOf: folder.appending(path: "pyproject.toml"), encoding: .utf8) else { return PyProject() }
        return pyproject(text: text)
    }

    public static func pyproject(text: String) -> PyProject {
        var result = PyProject()
        for line in text.split(whereSeparator: \.isNewline) {
            let header = line.trimmingCharacters(in: .whitespaces)
            if header == "[project]" { result.isProject = true }
            if header == "[tool.poetry]" { result.isPoetry = true }
            if header == "[build-system]" { result.hasBuildSystem = true }
        }
        return result
    }

    /// Target names of a Makefile (`name:` at column 0, no `=`, not `.PHONY`-style dot targets). Several targets on
    /// one line (`a b: deps`) all count.
    public static func makeTargets(_ text: String) -> Set<String> {
        var targets = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(" "), !line.hasPrefix(".") else { continue }
            let head = line[..<colon]
            guard !head.isEmpty, !head.contains("="), !head.contains("$") else { continue }
            let rest = line[line.index(after: colon)...]
            if rest.hasPrefix("=") { continue }   // `VAR := value`
            for name in head.split(separator: " ") where !name.isEmpty { targets.insert(String(name)) }
        }
        return targets
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
