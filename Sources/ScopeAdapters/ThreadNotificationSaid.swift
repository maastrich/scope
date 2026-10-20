import Foundation
import ScopeCore

extension ThreadNotificationContent.Said {
    /// What a notification about `event` can quote, `activity` being the thread's once `event` is folded in.
    ///
    /// A finished turn quotes the answer it carries — the whole of it, where `activity` only keeps its end — and
    /// nothing when it carries none: the one `activity` holds is then an earlier turn's. A
    /// question quotes itself when the hook says it, else the last answer, but only one given since the last turn
    /// started: a question tool fires mid-turn, and the answer before it belongs to an earlier exchange.
    public static func from(_ event: AdapterEvent, activity: ThreadActivity) -> Self? {
        switch event.kind {
        case .turnEnded:
            return AgentReply.from(event).map { .reply($0.text) }
        case .inputRequested:
            if let question = event.raw.flatMap({ HookStdin.parse(Data($0.utf8)).question }) {
                return .question(question)
            }
            guard let reply = activity.lastReply else { return nil }
            let started = [activity.turnStartedAt, activity.turns.last?.startedAt].compactMap(\.self).max()
            if let started, started > reply.at { return nil }
            return .reply(reply.text)
        case .turnStarted, .turnFailed, .permissionRequested, .threadEnded, .sessionStarted, .turnSaid, .agentStarted, .agentEnded, .limitsReported:
            return nil
        }
    }
}
