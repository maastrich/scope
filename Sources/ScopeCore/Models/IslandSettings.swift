import Foundation

/// The island under the notch (spec §7): a floating surface at the top of a screen that shows what the Claude Code
/// threads are doing and lets the user answer them without bringing the window up. What it may do, from
/// `config.json`; every field has a default so a partial document decodes.
public struct IslandSettings: Codable, Sendable, Equatable {
    /// How the island opens from its collapsed shape.
    public enum Opening: String, Codable, Sendable, CaseIterable {
        /// Resting the pointer on it for a moment; leaving closes it.
        case hover
        /// A click; a click elsewhere closes it.
        case click
    }

    /// Which screen the island sits on.
    public enum Placement: String, Codable, Sendable, CaseIterable {
        /// The screen holding most of the frontmost window of the active app, whatever the app; the pointer's screen
        /// when that app shows no window. The default.
        case activeWindow
        /// The screen with the menu bar (System Settings ▸ Displays ▸ Main display).
        case main
        /// The screen the pointer is on, followed as it moves.
        case pointer
        /// The screen named `screenName`, else the main one while it is not connected.
        case named
    }

    /// `nil` — the default — is *automatic*: on in the installed app, off in a Debug build, so the copies a developer
    /// runs side by side do not stack islands at the same spot. The toggle in Settings writes `true` or `false`.
    public var enabled: Bool?
    public var opening: Opening
    public var placement: Placement
    /// `NSScreen.localizedName` of the chosen screen when `placement` is `.named`: display ids change when a screen is
    /// plugged in again, its name does not.
    public var screenName: String?
    /// A brief reveal when a thread finishes its turn. On by default.
    public var alertsOnFinish: Bool
    /// … when a turn fails. On by default.
    public var alertsOnFailure: Bool
    /// … when a thread asks a question, a permission or a plan's approval. On by default.
    public var alertsOnRequest: Bool
    /// A system sound with each reveal. Off by default: the notification already rings when the app is away.
    public var playsSound: Bool

    public init(enabled: Bool? = nil, opening: Opening = .hover, placement: Placement = .activeWindow, screenName: String? = nil,
                alertsOnFinish: Bool = true, alertsOnFailure: Bool = true, alertsOnRequest: Bool = true,
                playsSound: Bool = false) {
        self.enabled = enabled
        self.opening = opening
        self.placement = placement
        self.screenName = screenName
        self.alertsOnFinish = alertsOnFinish
        self.alertsOnFailure = alertsOnFailure
        self.alertsOnRequest = alertsOnRequest
        self.playsSound = playsSound
    }

    /// Whether the island shows, `automatic` being what `enabled == nil` means for this build.
    public func isEnabled(automatic: Bool) -> Bool { enabled ?? automatic }

    /// Written beside `placement` by every build since `activeWindow` became the default. v0.30.0 wrote `"main"` on
    /// any save, chosen or not, so a `"main"` without this stamp is that untouched default and reads as the new one;
    /// with it, `"main"` is the user's choice and stays.
    static let placementRevision = 2

    private enum CodingKeys: String, CodingKey {
        case enabled, opening, placement, placementRevision, screenName, alertsOnFinish, alertsOnFailure, alertsOnRequest,
             playsSound
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IslandSettings()
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        opening = (try? container.decodeIfPresent(Opening.self, forKey: .opening)) ?? defaults.opening
        placement = (try? container.decodeIfPresent(Placement.self, forKey: .placement)) ?? defaults.placement
        let revision = (try? container.decodeIfPresent(Int.self, forKey: .placementRevision)) ?? 1
        if placement == .main && revision < Self.placementRevision { placement = defaults.placement }
        screenName = try? container.decodeIfPresent(String.self, forKey: .screenName)
        alertsOnFinish = (try? container.decodeIfPresent(Bool.self, forKey: .alertsOnFinish)) ?? defaults.alertsOnFinish
        alertsOnFailure = (try? container.decodeIfPresent(Bool.self, forKey: .alertsOnFailure)) ?? defaults.alertsOnFailure
        alertsOnRequest = (try? container.decodeIfPresent(Bool.self, forKey: .alertsOnRequest)) ?? defaults.alertsOnRequest
        playsSound = (try? container.decodeIfPresent(Bool.self, forKey: .playsSound)) ?? defaults.playsSound
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encode(opening, forKey: .opening)
        try container.encode(placement, forKey: .placement)
        try container.encode(Self.placementRevision, forKey: .placementRevision)
        try container.encodeIfPresent(screenName, forKey: .screenName)
        try container.encode(alertsOnFinish, forKey: .alertsOnFinish)
        try container.encode(alertsOnFailure, forKey: .alertsOnFailure)
        try container.encode(alertsOnRequest, forKey: .alertsOnRequest)
        try container.encode(playsSound, forKey: .playsSound)
    }
}
