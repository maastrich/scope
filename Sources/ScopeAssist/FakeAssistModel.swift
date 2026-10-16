import Foundation
import Synchronization

/// A model for tests and previews: answers from a script, records what it was asked.
public final class FakeAssistModel: AssistModel, Sendable {
    public struct Call: Sendable, Equatable {
        public var job: AssistJob.Kind
        public var instructions: String
        public var input: String
    }

    private struct State {
        var answers: [AssistJob.Kind: [any Sendable]] = [:]
        var calls: [Call] = []
        var available = true
    }

    private let state = Mutex(State())
    public let tier: AssistTier

    public init(tier: AssistTier = .onDevice, available: Bool = true) {
        self.tier = tier
        state.withLock { $0.available = available }
    }

    public var isAvailable: Bool {
        get async { state.withLock { $0.available } }
    }

    public func setAvailable(_ available: Bool) {
        state.withLock { $0.available = available }
    }

    /// Queues `answer` for the next call of its job; several queue in order, the last one repeats.
    public func answer<T: Sendable>(_ job: AssistJob.Kind, with answer: T) {
        state.withLock { $0.answers[job, default: []].append(answer) }
    }

    public var calls: [Call] { state.withLock { $0.calls } }

    public func classify<T: Decodable & Sendable>(instructions: String, input: String, schema: AssistSchema) async throws -> T {
        try state.withLock { state in
            state.calls.append(Call(job: schema.job, instructions: instructions, input: input))
            guard state.available else { throw AssistError.unavailable }
            guard var queue = state.answers[schema.job], let next = queue.first else { throw AssistError.malformedAnswer("no scripted answer") }
            if queue.count > 1 { queue.removeFirst() }
            state.answers[schema.job] = queue
            guard let typed = next as? T else { throw AssistError.malformedAnswer("scripted answer is a \(type(of: next))") }
            return typed
        }
    }
}
