import AppKit
import Foundation
import ScopeControl
import ScopeCore

/// The model's part of the usage log: starting it, the gestures only the model sees (a sidebar selection, a swipe, a
/// preference), and reading it back for `scope usage`.
extension AppModel {
    /// After the config is read: recording follows the preference, the history past its retention goes.
    func startUsage() {
        Usage.recorder = env.usage
        Usage.currentScope = { [weak self] in self?.currentScopeID?.rawValue }
        env.usage.setEnabled(config.preferences.recordUsage)
        UsageMenuTracker.install()
        let usage = env.usage
        Task { await usage.prune() }
    }

    /// Drops the history and keeps recording, if it was.
    func clearUsageHistory() async {
        await env.usage.clear()
    }

    /// A row picked with the pointer. Selections made by a command, the palette, a notification or the app itself
    /// are counted where they come from, or not at all.
    func noteSelectionClick() {
        guard !Usage.attributing, Usage.currentInput == .mouse, let selection else { return }
        let element = switch selection {
        case .scope: "scope"
        case .repo: "repo"
        case .thread: "thread"
        case .task: "task"
        }
        Usage.click("sidebar.\(element)", label: "\(element.capitalized) row")
    }

    /// A two-finger swipe over the sidebar; ⌥⌘← / → are counted as menu commands.
    func noteScopeSwipe() {
        switch NSApp.currentEvent?.type {
        case .scrollWheel, .swipe, .gesture:
            Usage.register("sidebar.swipe-scope", label: "Swipe between scopes")
            Usage.record(.click, "sidebar.swipe-scope", source: .mouse)
        default:
            break
        }
    }

    /// Which preferences changed, by key. Never the value: an editor command or a driver id is the user's business.
    func noteSettingsChanged(from before: Preferences) {
        let keys = UsageID.changedKeys(before, config.preferences)
        for key in keys {
            Usage.register("setting.\(key)", label: key)
            Usage.record(.setting, "setting.\(key)", source: Usage.currentInput ?? .app)
        }
        // After the event, so turning recording off is the last thing recorded; turning it on is not recorded, since
        // the event went to a recorder still off.
        if before.recordUsage != config.preferences.recordUsage {
            env.usage.setEnabled(config.preferences.recordUsage)
        }
    }

    /// `scope usage`: everything queued is written first, then the files are read off the main actor.
    func usageReport(_ params: UsageParams) async -> Result<ControlResultPayload, ControlError> {
        let timeZone = TimeZone.current
        guard let period = ActivityPeriod.parse(params.period, calendar: ActivityPeriod.calendar(timeZone)) else {
            return .failure(.badRequest("no period called “\(params.period ?? "")”", detail: ActivityPeriod.grammar))
        }
        await env.usage.flush()
        let log = env.usage.log
        let recording = config.preferences.recordUsage
        let result = await Task.detached(priority: .userInitiated) {
            let previous = UsageReport.previous(of: period)
            let events = log.read(since: previous.since, until: period.until)
            let historySince = log.firstEventDate()
            return UsageReport.build(period: period, timeZone: timeZone,
                                     events: events.filter { period.contains($0.at) },
                                     previousEvents: events.filter { previous.contains($0.at) },
                                     registry: log.readRegistry(), recording: recording, historySince: historySince,
                                     area: params.area, limit: params.limit ?? UsageReport.defaultLimit)
        }.value
        return .success(.usage(result))
    }
}
