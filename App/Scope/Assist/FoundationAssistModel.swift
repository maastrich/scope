import Foundation
import ScopeAssist
import ScopeCore

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model as the first tier of the assistant (spec §4.10): free, local, and only asked for
/// structured answers, which is what the research note found it good at.
///
/// A session is made per call rather than kept per job: each answer stays in a session's transcript, and with 4 k
/// tokens of context a second 3 k tail would not fit. `prewarm()` once at launch loads the model for every session
/// that follows. The `@Generable` mirrors are encoded to JSON and decoded as the package's job values, so the
/// package never imports the framework.
@available(macOS 26, *)
actor FoundationAssistModel: AssistModel {
    nonisolated let tier: AssistTier = .onDevice
    private var warmed = false

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the model cannot answer, in words, or `nil` when it can.
    nonisolated static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off in System Settings"
        case .unavailable(.deviceNotEligible): "this Mac cannot run Apple Intelligence"
        case .unavailable(.modelNotReady): "the model is still downloading"
        case .unavailable: "unavailable"
        }
    }

    nonisolated static var contextSize: Int { SystemLanguageModel.default.contextSize }

    /// Loads the model once; later sessions answer warm.
    func prewarm() {
        guard !warmed, isAvailable else { return }
        warmed = true
        LanguageModelSession(instructions: assistPreambleForPrewarm).prewarm()
    }

    private nonisolated var assistPreambleForPrewarm: String { ThreadDigest.instructions }

    func classify<T: Decodable & Sendable>(instructions: String, input: String, schema: AssistSchema) async throws -> T {
        guard isAvailable else { throw AssistError.unavailable }
        let session = LanguageModelSession(instructions: instructions)
        let data: Data
        switch schema.job {
        case .threadDigest:
            data = try JSONEncoder().encode(try await session.respond(to: input, generating: GeneratedDigest.self).content)
        case .notificationTriage:
            data = try JSONEncoder().encode(try await session.respond(to: input, generating: GeneratedTriage.self).content)
        case .archiveHint:
            data = try JSONEncoder().encode(try await session.respond(to: input, generating: GeneratedArchiveHint.self).content)
        case .topicPick:
            data = try JSONEncoder().encode(try await session.respond(to: input, generating: GeneratedTopicPick.self).content)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AssistError.malformedAnswer(String(decoding: data, as: UTF8.self))
        }
    }
}

@available(macOS 26, *)
@Generable
private struct GeneratedDigest: Encodable {
    @Guide(description: "What the agent is doing right now, max 8 words, present tense, no subject")
    var activity: String
    @Guide(description: "true if the agent is stuck: the same error or command repeated with no progress, or waiting for something it cannot get")
    var stuck: Bool
    @Guide(description: "One short reason if stuck, else empty")
    var reason: String
}

@available(macOS 26, *)
@Generable
private struct GeneratedTriage: Encodable {
    @Guide(description: "blockingQuestion when the agent cannot go on without the person's answer or decision; failure when it stopped on an error it could not fix; informational otherwise")
    var kind: GeneratedTriageKind
}

@available(macOS 26, *)
@Generable
private enum GeneratedTriageKind: String, Encodable {
    case blockingQuestion, informational, failure
}

@available(macOS 26, *)
@Generable
private struct GeneratedArchiveHint: Encodable {
    @Guide(description: "true if the message is a final deliverable: a report, a conclusion, a summary of finished work, with nothing left pending")
    var looksFinished: Bool
    @Guide(description: "A few words saying why")
    var reason: String
}

@available(macOS 26, *)
@Generable
private struct GeneratedTopicPick: Encodable {
    @Guide(description: "One of the listed topics, spelled exactly as listed, or \"none\" when none fits")
    var topic: String
}
#endif
