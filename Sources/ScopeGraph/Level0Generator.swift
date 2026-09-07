import CryptoKit
import Foundation
import ScopeCore
import ScopeGit

/// What the filesystem alone says about a repo (no git): the card fields inferred from the README
/// and the manifests, plus the content hashes that feed the cache key.
public struct Level0Analysis: Sendable, Equatable {
    public var purpose: String?
    public var stack: [String]
    public var entrypoints: [String]
    public var setup: String?
    public var test: String?
    public var tags: [String]
    /// SHA-256 of the README (empty string hashed when there is none).
    public var readmeHash: String
    /// SHA-256 over the sorted manifests (name + content) and lockfile names.
    public var manifestsHash: String
    /// Manifest file names found at the repo root.
    public var manifests: [String]
}

/// Level 0 generation (spec §4.6): README first paragraph + manifests, without AI. Pure functions
/// except `generate`, which adds the git-backed fields through a `GitClient`.
public enum Level0Generator {
    /// Manifest names looked for at the repo root, in the order they contribute to the analysis.
    public static let manifestNames = [
        "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Package.swift", "Gemfile", "Makefile",
    ]
    static let lockfiles = [
        "pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn", "bun.lockb": "bun", "bun.lock": "bun", "package-lock.json": "npm",
    ]
    static let readmeNames = ["readme.md", "readme", "readme.markdown", "readme.txt", "readme.rst"]

    // MARK: - Full card

    /// L0 card of `repo`: `analyze` + HEAD sha, last activity, remote and default branch through `client`.
    /// Never throws: a failing git command leaves its field `nil`.
    public static func generate(repo: URL, name: String, using client: GitClient) async -> (card: RepoCard, cacheKey: String) {
        let analysis = analyze(repo: repo)
        let facts = await RepoFacts.load(for: repo, using: client)
        var card = RepoCard(
            name: name,
            remote: facts.remote?.fullName ?? facts.originURL,
            defaultBranch: facts.defaultBranch,
            purpose: analysis.purpose,
            stack: analysis.stack,
            entrypoints: analysis.entrypoints,
            setup: analysis.setup,
            test: analysis.test,
            tags: analysis.tags,
            generatedBy: .level0
        )
        if let iso = try? await client.output(["log", "-1", "--format=%cI"], timeout: RepoFacts.commandTimeout),
           let date = ISO8601DateFormatter().date(from: iso) {
            card.lastActivity = date
        }
        let head = (try? await client.output(["rev-parse", "HEAD"], timeout: RepoFacts.commandTimeout)) ?? "unborn"
        return (card, cacheKey(headSHA: head, analysis: analysis))
    }

    /// Cache key of `repo` without building the card (used to decide whether to skip).
    public static func cacheKey(repo: URL, using client: GitClient) async -> String {
        let head = (try? await client.output(["rev-parse", "HEAD"], timeout: RepoFacts.commandTimeout)) ?? "unborn"
        return cacheKey(headSHA: head, analysis: analyze(repo: repo))
    }

    /// `<head>:<readme-hash>:<manifests-hash>` (spec §4.6).
    public static func cacheKey(headSHA: String, analysis: Level0Analysis) -> String {
        "\(headSHA):\(analysis.readmeHash):\(analysis.manifestsHash)"
    }

    // MARK: - Filesystem analysis

    /// Reads the README and the manifests of `repo`. Pure: no git, no subprocess.
    public static func analyze(repo: URL) -> Level0Analysis {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        let byLowercase = Dictionary(entries.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        let readmeText = readmeNames.lazy
            .compactMap { byLowercase[$0] }
            .compactMap { try? String(contentsOf: repo.appending(path: $0), encoding: .utf8) }
            .first ?? ""

        var analysis = Level0Analysis(
            purpose: readmeText.isEmpty ? nil : firstParagraph(ofReadme: readmeText),
            stack: [], entrypoints: [], setup: nil, test: nil, tags: [],
            readmeHash: sha256(readmeText), manifestsHash: "", manifests: []
        )

        var hashInput = ""
        for name in manifestNames {
            guard entries.contains(name), let text = try? String(contentsOf: repo.appending(path: name), encoding: .utf8) else { continue }
            analysis.manifests.append(name)
            hashInput += "\(name)\n\(text)\n"
            apply(manifest: name, text: text, repo: repo, entries: entries, to: &analysis)
        }
        for lock in lockfiles.keys.sorted() where entries.contains(lock) {
            hashInput += "lock:\(lock)\n"
        }
        analysis.manifestsHash = sha256(hashInput)

        var tags = analysis.stack
        if analysis.tags.contains("monorepo") { tags.append("monorepo") }
        analysis.tags = unique(tags)
        analysis.stack = unique(analysis.stack)
        analysis.entrypoints = unique(analysis.entrypoints)
        return analysis
    }

    /// First non-heading paragraph of a README, badges and HTML stripped, at most three sentences.
    public static func firstParagraph(ofReadme text: String) -> String? {
        var paragraph: [String] = []
        var inFence = false
        var inHTMLComment = false
        let rawLines = text.components(separatedBy: .newlines)
        for (offset, rawLine) in rawLines.enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // Setext heading: a text line underlined with `===` / `---`.
            if paragraph.isEmpty, offset + 1 < rawLines.count, isUnderline(rawLines[offset + 1]) { continue }
            if inHTMLComment {
                guard let end = line.range(of: "-->") else { continue }
                line = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                inHTMLComment = false
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            if line.hasPrefix("<!--") {
                if let end = line.range(of: "-->") {
                    line = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    inHTMLComment = true
                    continue
                }
            }
            if line.hasPrefix("> ") || line == ">" { line = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces) }
            let cleaned = stripMarkup(line)
            let isBlank = cleaned.isEmpty
            let isHeading = line.hasPrefix("#") || isUnderline(line)
            let isBadgeOrImage = isBadgeLine(line)
            if isBlank || isHeading || isBadgeOrImage {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(cleaned)
        }
        guard !paragraph.isEmpty else { return nil }
        let joined = paragraph.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        return firstSentences(joined, max: 3)
    }

    /// `===`, `---` (at least two characters).
    static func isUnderline(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2 && (trimmed.allSatisfy { $0 == "=" } || trimmed.allSatisfy { $0 == "-" })
    }

    // MARK: - Manifests

    private static func apply(manifest: String, text: String, repo: URL, entries: [String], to a: inout Level0Analysis) {
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: repo.appending(path: $0).path) }
        switch manifest {
        case "package.json":
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            let scripts = json["scripts"] as? [String: Any] ?? [:]
            let devDeps = json["devDependencies"] as? [String: Any] ?? [:]
            let pm = packageManager(json: json, entries: entries)
            a.stack.append("node")
            if entries.contains("tsconfig.json") || devDeps["typescript"] != nil { a.stack.append("typescript") }
            for framework in ["next", "react", "vue", "svelte", "express", "fastify", "nest", "@nestjs/core", "vite"] {
                if (json["dependencies"] as? [String: Any])?[framework] != nil || devDeps[framework] != nil {
                    a.stack.append(framework.hasPrefix("@nestjs") ? "nest" : framework)
                }
            }
            a.setup = "\(pm) install"
            if scripts["test"] != nil { a.test = "\(pm) test" }
            if let main = json["main"] as? String { a.entrypoints.append(main) }
            if let bin = json["bin"] as? String { a.entrypoints.append(bin) }
            if let bins = json["bin"] as? [String: Any] { a.entrypoints += bins.values.compactMap { $0 as? String }.sorted() }
            if json["workspaces"] != nil || entries.contains("pnpm-workspace.yaml") { a.tags.append("monorepo") }
            for script in ["dev", "build"] where scripts[script] != nil { a.tags.append("script:\(script)") }
        case "Cargo.toml":
            a.stack.append("rust")
            a.setup = a.setup ?? "cargo build"
            a.test = a.test ?? "cargo test"
            for candidate in ["src/main.rs", "src/lib.rs"] where exists(candidate) { a.entrypoints.append(candidate) }
            if text.contains("[workspace]") { a.tags.append("monorepo") }
        case "pyproject.toml":
            a.stack.append("python")
            if text.contains("[tool.poetry]") {
                a.setup = a.setup ?? "poetry install"
                a.test = a.test ?? "poetry run pytest"
            } else if entries.contains("uv.lock") {
                a.setup = a.setup ?? "uv sync"
                a.test = a.test ?? "uv run pytest"
            } else {
                a.setup = a.setup ?? "pip install -e ."
                a.test = a.test ?? "pytest"
            }
        case "go.mod":
            a.stack.append("go")
            a.setup = a.setup ?? "go mod download"
            a.test = a.test ?? "go test ./..."
            if exists("main.go") { a.entrypoints.append("main.go") }
            if let cmds = try? FileManager.default.contentsOfDirectory(atPath: repo.appending(path: "cmd").path) {
                a.entrypoints += cmds.sorted().map { "cmd/\($0)" }
            }
        case "Package.swift":
            a.stack.append("swift")
            a.setup = a.setup ?? "swift build"
            a.test = a.test ?? "swift test"
        case "Gemfile":
            a.stack.append("ruby")
            a.setup = a.setup ?? "bundle install"
            a.test = a.test ?? (exists("spec") ? "bundle exec rspec" : "bundle exec rake test")
        case "Makefile":
            let targets = makeTargets(text)
            if a.setup == nil, let target = ["setup", "install", "deps", "bootstrap"].first(where: targets.contains) {
                a.setup = "make \(target)"
            }
            if a.test == nil, targets.contains("test") { a.test = "make test" }
            a.stack.append("make")
        default:
            break
        }
    }

    static func packageManager(json: [String: Any], entries: [String]) -> String {
        if let declared = json["packageManager"] as? String,
           let name = declared.split(separator: "@").first, !name.isEmpty {
            return String(name)
        }
        for (lock, pm) in lockfiles.sorted(by: { $0.key < $1.key }) where entries.contains(lock) {
            return pm
        }
        return "npm"
    }

    /// Target names of a Makefile (`name:` at column 0, no `=`, not `.PHONY`-style dot targets).
    static func makeTargets(_ text: String) -> Set<String> {
        var targets = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(" "), !line.hasPrefix(".") else { continue }
            let head = line[..<colon]
            guard !head.isEmpty, !head.contains("="), !head.contains(" "), !head.contains("$") else { continue }
            let rest = line[line.index(after: colon)...]
            if rest.hasPrefix("=") { continue }   // `VAR := value`
            targets.insert(String(head))
        }
        return targets
    }

    // MARK: - Text helpers

    /// `true` for a line made only of badges / images / HTML tags.
    static func isBadgeLine(_ line: String) -> Bool {
        var rest = Substring(line)
        var sawSomething = false
        while !rest.isEmpty {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.isEmpty { break }
            if rest.hasPrefix("[![") || rest.hasPrefix("![") {
                // image, optionally wrapped in a link: skip to the matching `)` (and the `](…)` link tail)
                guard let close = rest.firstIndex(of: ")") else { return false }
                rest = rest[rest.index(after: close)...]
                if rest.hasPrefix("](") {
                    guard let close2 = rest.firstIndex(of: ")") else { return false }
                    rest = rest[rest.index(after: close2)...]
                }
                sawSomething = true
            } else if rest.hasPrefix("<") {
                guard let close = rest.firstIndex(of: ">") else { return false }
                rest = rest[rest.index(after: close)...]
                sawSomething = true
            } else {
                return false
            }
        }
        return sawSomething
    }

    /// Removes HTML tags, images, link syntax (keeps the text) and emphasis markers.
    static func stripMarkup(_ line: String) -> String {
        var s = line
        s = s.replacing(/<[^>]+>/, with: "")
        s = s.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")
        s = s.replacing(/\[([^\]]*)\]\([^)]*\)/) { m in String(m.output.1) }
        s = s.replacing(/\*\*|__/, with: "")
        s = s.replacingOccurrences(of: "\t", with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The first `max` sentences of `text` (split on `. `, `! `, `? `).
    static func firstSentences(_ text: String, max: Int) -> String {
        var sentences: [String] = []
        var current = ""
        var previous: Character = " "
        for character in text {
            current.append(character)
            if character == " ", ".!?".contains(previous) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                if sentences.count == max { return sentences.joined(separator: " ") }
            }
            previous = character
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.prefix(max).joined(separator: " ")
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
