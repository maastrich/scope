import Foundation

/// What kind of Claude account the user signed Claude Code in with, read from the `oauthAccount` Claude Code keeps in
/// `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`). Read only; the file is Claude Code's.
///
/// The plan says how usage should read: a subscription (Pro, Max) is limited by windows of time, so the meter shows
/// percentages of them; an API key or console account is billed per token, so it shows tokens and cost. The decisive
/// signal for the meter is whether `rate_limits` arrive at all — Claude Code sends them to subscribers only — and
/// this is the label to put on them, with a fallback when the file says nothing.
public struct ClaudeAccount: Codable, Sendable, Equatable {
    /// `claude_max`, `claude_pro`, `claude_team`, `claude_enterprise`, `api`, … as the file has it.
    public var organizationType: String?
    /// `default_claude_max_20x`, `default_claude_max_5x`, `default_claude_pro`, … — the tier the limits follow.
    public var rateLimitTier: String?
    /// `stripe_subscription`, `prepaid`, `invoice`, …
    public var billingType: String?

    public init(organizationType: String? = nil, rateLimitTier: String? = nil, billingType: String? = nil) {
        self.organizationType = organizationType
        self.rateLimitTier = rateLimitTier
        self.billingType = billingType
    }

    /// `nil` when the file has no `oauthAccount`: Claude Code is signed in with an API key, or not at all.
    public static func parse(_ data: Data) -> ClaudeAccount? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            (account[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return ClaudeAccount(organizationType: text("organizationType"),
                             rateLimitTier: text("userRateLimitTier") ?? text("organizationRateLimitTier"),
                             billingType: text("billingType"))
    }

    /// Where Claude Code keeps the file: `$CLAUDE_CONFIG_DIR/.claude.json` when that is set, else `~/.claude.json`.
    public static func fileURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appending(path: ".claude.json", directoryHint: .notDirectory)
        }
        return home.appending(path: ".claude.json", directoryHint: .notDirectory)
    }

    public static func read(at url: URL = fileURL()) -> ClaudeAccount? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// `true` for an account whose limits are windows of time rather than a token bill.
    public var isSubscription: Bool {
        if let tier = rateLimitTier?.lowercased(), tier.contains("max") || tier.contains("pro") { return true }
        if let type = organizationType?.lowercased(), type.hasPrefix("claude_") { return true }
        return billingType?.lowercased().contains("subscription") == true
    }

    /// The plan as a person would name it: `Max 20×`, `Max 5×`, `Max`, `Pro`, `Team`, `Enterprise`; `nil` when the
    /// file gives nothing to go on.
    public var planLabel: String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Max 20×" }
        if tier.contains("max_5x") { return "Max 5×" }
        if tier.contains("max") { return "Max" }
        if tier.contains("pro") { return "Pro" }
        switch organizationType?.lowercased() {
        case "claude_max"?: return "Max"
        case "claude_pro"?: return "Pro"
        case "claude_team"?: return "Team"
        case "claude_enterprise"?: return "Enterprise"
        case let type? where type.hasPrefix("claude_"):
            return type.dropFirst("claude_".count).replacingOccurrences(of: "_", with: " ").capitalized
        default: return nil
        }
    }
}
