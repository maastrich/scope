import Foundation

/// A GitHub issue as `gh issue view --json` describes it: what a task opened from it needs for its brief.
public struct Issue: Sendable, Equatable, Hashable {
    public var number: Int
    public var title: String
    public var body: String
    public var labels: [String]
    public var url: URL
    public var state: String
    /// `owner/name`, read off the URL.
    public var repository: String?

    public init(number: Int, title: String, body: String = "", labels: [String] = [], url: URL, state: String = "OPEN") {
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels
        self.url = url
        self.state = state
        let parts = url.pathComponents.filter { $0 != "/" }
        repository = parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    public var label: String { "#\(number)" }

    public static let jsonFields = "number,title,body,labels,url,state"

    private struct DTO: Decodable {
        struct Label: Decodable { var name: String }
        var number: Int
        var title: String
        var body: String?
        var labels: [Label]?
        var url: URL
        var state: String?
    }

    /// Parses the output of `gh issue view --json …` (a single object).
    public static func parseOne(json: Data) throws -> Issue {
        let dto = try JSONDecoder().decode(DTO.self, from: json)
        return Issue(number: dto.number, title: dto.title, body: dto.body ?? "", labels: (dto.labels ?? []).map(\.name),
                     url: dto.url, state: dto.state ?? "OPEN")
    }
}
