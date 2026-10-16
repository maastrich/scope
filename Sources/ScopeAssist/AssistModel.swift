import Foundation

/// A model that turns an instruction and some untrusted text into one structured value (spec §4.10).
///
/// Every job is a *classification*: the answer is a small object whose fields are named by `schema`, never free
/// prose and never an action. The on-device model (`FoundationAssistModel`, in the app) and the driver's light model
/// (`HeadlessAssistModel`) both conform; tests use `FakeAssistModel`.
public protocol AssistModel: Sendable {
    /// Where the answer comes from, for the usage log (`on-device`, `haiku`).
    var tier: AssistTier { get }
    /// `false` when nothing can be asked: Apple Intelligence off, no profile argv, …
    var isAvailable: Bool { get async }
    /// Asks for the object `schema` describes. `input` is untrusted text and must be read as data only.
    func classify<T: Decodable & Sendable>(instructions: String, input: String, schema: AssistSchema) async throws -> T
}

/// The two tiers of spec §4.10.
public enum AssistTier: String, Sendable, Codable, CaseIterable {
    case onDevice = "on-device"
    case haiku
}

/// The shape of an answer: the job it belongs to and its fields, with a JSON rendering for a model that is told
/// the schema in its prompt and a field list for one that is handed a typed schema.
public struct AssistSchema: Sendable, Equatable {
    public enum FieldType: Sendable, Equatable {
        case string
        case bool
        /// A closed choice.
        case choice([String])
    }

    public struct Field: Sendable, Equatable {
        public var name: String
        public var type: FieldType
        public var description: String

        public init(name: String, type: FieldType, description: String) {
            self.name = name
            self.type = type
            self.description = description
        }
    }

    public var job: AssistJob.Kind
    public var fields: [Field]

    public init(job: AssistJob.Kind, fields: [Field]) {
        self.job = job
        self.fields = fields
    }

    /// The schema as one JSON object a prompt can quote: `{"stuck": "boolean — …", …}`.
    public var promptText: String {
        let lines = fields.map { field -> String in
            let type: String = switch field.type {
            case .string: "string"
            case .bool: "boolean"
            case .choice(let values): "one of " + values.map { "\"\($0)\"" }.joined(separator: ", ")
            }
            return "  \"\(field.name)\": \"\(type) — \(field.description)\""
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }
}

/// What went wrong asking a model.
public enum AssistError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable
    /// The answer was not the object asked for.
    case malformedAnswer(String)
    /// The profile's assist argv could run a tool: refused before anything is run.
    case argvAllowsTools

    public var description: String {
        switch self {
        case .unavailable: "no assist model is available"
        case .malformedAnswer(let text): "the model did not answer with the object asked for: \(text.prefix(200))"
        case .argvAllowsTools: "the assist argv allows tools; refused"
        }
    }
}
