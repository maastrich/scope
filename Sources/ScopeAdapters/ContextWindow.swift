import Foundation
import ScopeCore

/// How full a session's context window is, as Claude Code reports it to its status line, with the model it runs
/// and its own version.
///
/// Source: the same status-line JSON `RateLimits` comes from (code.claude.com/docs/en/statusline). `context_window`
/// carries `used_percentage` (0–100), `context_window_size` and the tokens of the current turn; `model` the id and
/// its `display_name`; `version` the CLI's. Unlike the limits, this is about *one* session: `scope-hook statusline`
/// forwards it on the same `limits.reported` event (`payload["context"]`) and the app keeps it on the thread.
/// Nothing is estimated: a driver that reports no context window shows no gauge.
public struct ContextWindowReport: Codable, Sendable, Equatable {
    /// 0–100; `nil` when the payload had a `context_window` without a readable percentage.
    public var usedPercentage: Double?
    /// Tokens the window holds, when said.
    public var windowSize: Int?
    public var modelID: String?
    /// `Fable 5.1`, as the driver names it.
    public var modelName: String?
    /// The driver's own version (`2.1.47`).
    public var driverVersion: String?
    /// When the status line was written.
    public var reportedAt: Date

    public init(usedPercentage: Double? = nil, windowSize: Int? = nil, modelID: String? = nil, modelName: String? = nil,
                driverVersion: String? = nil, reportedAt: Date) {
        self.usedPercentage = usedPercentage
        self.windowSize = windowSize
        self.modelID = modelID
        self.modelName = modelName
        self.driverVersion = driverVersion
        self.reportedAt = reportedAt
    }

    /// `usedPercentage` clamped to 0…1 for a gauge, `nil` when unknown.
    public var fraction: Double? {
        usedPercentage.map { min(max($0 / 100, 0), 1) }
    }

    /// `38 %`, or `nil` when the percentage is unknown.
    public var percentageText: String? {
        usedPercentage.map { "\(Int($0.rounded())) %" }
    }

    // MARK: Parsing

    private static let keys = ["used_percentage", "context_window_size", "model_id", "model_name", "version"]

    /// The parts of a status-line payload this report keeps, as one compact JSON object for the hook's payload.
    /// `nil` when the payload says nothing of the kind (no `context_window`, no `model`, no `version`).
    public static func extract(statusline data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var picked: [String: Any] = [:]
        if let window = object["context_window"] as? [String: Any] {
            if let used = window["used_percentage"] as? NSNumber { picked["used_percentage"] = used }
            if let size = window["context_window_size"] as? NSNumber { picked["context_window_size"] = size }
        }
        if let model = object["model"] as? [String: Any] {
            if let id = model["id"] as? String, !id.isEmpty { picked["model_id"] = id }
            if let name = model["display_name"] as? String, !name.isEmpty { picked["model_name"] = name }
        }
        if let version = object["version"] as? String, !version.isEmpty { picked["version"] = version }
        guard !picked.isEmpty,
              let encoded = try? JSONSerialization.data(withJSONObject: picked, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Parses what `extract` serialized. `nil` for anything that is not a JSON object or carries none of the keys.
    public static func parse(_ json: String, reportedAt: Date) -> ContextWindowReport? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              keys.contains(where: { object[$0] != nil }) else { return nil }
        var report = ContextWindowReport(reportedAt: reportedAt)
        if let used = (object["used_percentage"] as? NSNumber)?.doubleValue, used.isFinite { report.usedPercentage = used }
        if let size = (object["context_window_size"] as? NSNumber)?.intValue, size > 0 { report.windowSize = size }
        report.modelID = (object["model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        report.modelName = (object["model_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        report.driverVersion = (object["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return report
    }
}
