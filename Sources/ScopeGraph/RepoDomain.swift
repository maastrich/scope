import Foundation

/// What part of a system a repository is: the groups of the Graph sheet. The AI analysis may name one; otherwise
/// `infer` reads it from the card's stack, tags and name.
public enum RepoDomain: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
    case frontend, backend, library, infra, data, mobile, docs, tooling, other

    /// Group order in the sheet: what people open most first, the catch-all last.
    public static func < (lhs: RepoDomain, rhs: RepoDomain) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var title: String {
        switch self {
        case .frontend: "Front"
        case .backend: "Back"
        case .library: "Libs"
        case .infra: "Infra & CI"
        case .data: "Data"
        case .mobile: "Mobile"
        case .docs: "Docs & design"
        case .tooling: "Tools"
        case .other: "Other"
        }
    }

    /// The domain a card says it is in: the AI's answer when it names a known domain, else `infer`.
    public static func of(_ card: RepoCard, key: String = "") -> RepoDomain {
        if let raw = card.domain?.lowercased(), let named = RepoDomain(rawValue: raw) { return named }
        return infer(stack: card.stack, tags: card.tags, name: card.name.isEmpty ? key : card.name,
                     description: RepoDescription.choose(for: card)?.text ?? "")
    }

    /// The groups of the Cards view: domains in `RepoDomain` order, each with its repos sorted by key. A domain with
    /// fewer than `minimum` repos does not get a group of its own — eight groups of one card is a list with headers
    /// in it — and joins the others like it in a last group named after all of them.
    public static func groups(_ items: [(key: String, domain: RepoDomain)], minimum: Int = 2) -> [DomainGroup] {
        let byDomain = Dictionary(grouping: items, by: \.domain).sorted { $0.key < $1.key }
            .map { (domain: $0.key, keys: $0.value.map(\.key).sorted()) }
        let small = byDomain.filter { $0.keys.count < minimum }
        // Merging a single small domain into nothing would only rename it.
        guard small.count > 1 else { return byDomain.map { DomainGroup(domains: [$0.domain], keys: $0.keys) } }
        var groups = byDomain.filter { $0.keys.count >= minimum }.map { DomainGroup(domains: [$0.domain], keys: $0.keys) }
        groups.append(DomainGroup(domains: small.map(\.domain), keys: small.flatMap(\.keys)))
        return groups
    }

    /// Scores every domain by the signals found in `stack`, `tags` and the words of `name`, and keeps the best one.
    /// Signals in the name weigh more: a repository called `*-infra` is infrastructure whatever it is written in.
    /// The words of the description count once each, at a weight of one: "the ad platform backend in PHP" is a hint,
    /// not a tag. Ties go to the domain listed first in `RepoDomain.allCases`, so the answer never depends on input
    /// order.
    public static func infer(stack: [String], tags: [String], name: String, description: String = "") -> RepoDomain {
        var scores: [RepoDomain: Int] = [:]
        for item in (stack + tags).map(TagMerge.normalize) {
            for (domain, weight) in signals[item] ?? [] { scores[domain, default: 0] += weight }
        }
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in words {
            for (domain, weight) in nameSignals[word] ?? [] { scores[domain, default: 0] += weight }
        }
        let prose = Set(description.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for word in prose {
            for (domain, _) in nameSignals[word] ?? [] { scores[domain, default: 0] += 1 }
        }
        guard let best = scores.values.max(), best > 0 else { return .other }
        return allCases.first { scores[$0] == best } ?? .other
    }

    /// Normalized tag → domains it points to, with a weight. Frameworks are strong signals, runtimes weak: `node`
    /// alone says nothing about the side a repository is on.
    static let signals: [String: [(RepoDomain, Int)]] = {
        var table: [String: [(RepoDomain, Int)]] = [:]
        func add(_ domain: RepoDomain, _ weight: Int, _ tags: String) {
            for tag in tags.split(separator: " ") { table[String(tag), default: []].append((domain, weight)) }
        }
        add(.frontend, 3, "next react vue svelte angular nuxt remix astro solid tailwind css scss frontend front web spa pwa vite storybook")
        add(.frontend, 2, "html ui webapp")
        add(.backend, 3, "express fastify nest django flask fastapi rails laravel symfony graphql grpc api backend server microservice lambda chalice serverless")
        add(.backend, 2, "php postgres mysql redis dynamodb mongodb prisma")
        add(.backend, 1, "go java kotlin ruby python")
        add(.library, 3, "library lib sdk package npm-package plugin eslint-config tsconfig vite-plugin")
        add(.library, 1, "typescript rust")
        add(.infra, 3, "terraform pulumi cloudformation cdk ansible kubernetes k8s helm infra infrastructure devops ci cd github-actions githubactions docker-image ecr aws-cdk deployment")
        add(.infra, 2, "docker dockercompose aws aws-cli gcp azure nginx")
        add(.data, 3, "dbt airflow spark kafka etl data pipeline warehouse bigquery snowflake jupyter pandas notebook ml analytics geo tileset")
        add(.mobile, 3, "ios android swiftui react-native expo flutter mobile")
        add(.docs, 3, "docs documentation markdown mdx design-system design-tokens branding figma docusaurus mkdocs")
        add(.tooling, 3, "cli tool tooling extension scaffold template generator automation bot script scripts gh-extension")
        return table
    }()

    /// Words of a repository name that say what it is.
    static let nameSignals: [String: [(RepoDomain, Int)]] = [
        "front": [(.frontend, 4)], "frontend": [(.frontend, 4)], "web": [(.frontend, 3)], "app": [(.frontend, 1)],
        "admin": [(.frontend, 2)], "site": [(.frontend, 3)], "ui": [(.frontend, 3)],
        "api": [(.backend, 4)], "server": [(.backend, 4)], "service": [(.backend, 3)], "microservice": [(.backend, 4)],
        "backend": [(.backend, 4)], "worker": [(.backend, 3)],
        "lib": [(.library, 4)], "libs": [(.library, 4)], "sdk": [(.library, 4)], "client": [(.library, 2)],
        "plugin": [(.library, 3)], "config": [(.library, 2)],
        "infra": [(.infra, 5)], "infrastructure": [(.infra, 5)], "terraform": [(.infra, 5)], "deploy": [(.infra, 4)],
        "ci": [(.infra, 4)], "actions": [(.infra, 4)], "build": [(.infra, 2)], "policy": [(.infra, 3)], "ops": [(.infra, 4)],
        "data": [(.data, 4)], "etl": [(.data, 5)], "warehouse": [(.data, 5)], "analytics": [(.data, 4)], "geo": [(.data, 3)],
        "ios": [(.mobile, 5)], "android": [(.mobile, 5)], "mobile": [(.mobile, 5)],
        "docs": [(.docs, 5)], "design": [(.docs, 4)], "doc": [(.docs, 4)],
        "cli": [(.tooling, 4)], "tool": [(.tooling, 4)], "tools": [(.tooling, 4)], "gh": [(.tooling, 3)],
        "template": [(.tooling, 4)], "scaffold": [(.tooling, 4)], "create": [(.tooling, 2)],
    ]
}

/// A group of the Cards view: one domain, or several small ones together.
public struct DomainGroup: Sendable, Equatable, Identifiable {
    public var domains: [RepoDomain]
    /// The repos, in display order.
    public var keys: [String]

    public init(domains: [RepoDomain], keys: [String]) {
        self.domains = domains
        self.keys = keys
    }

    /// Stable across launches: what the sheet remembers a fold by.
    public var id: String { domains.map(\.rawValue).joined(separator: "+") }
    public var title: String { domains.map(\.title).joined(separator: " · ") }
}
