import Foundation

/// A JSON value that is `Sendable` and `Equatable`, for the parts of Claude Code's payloads Scope keeps as they
/// come: a tool's input and result, the background tasks a `Stop` hook lists. Read with the subscripts and the
/// typed accessors, which answer `nil` for a missing key or a value of another type — a payload that changed shape
/// reads as absent, never as a crash.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts what `JSONSerialization` returns; anything else (a `Date`, a custom object) becomes `null`.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            // `JSONSerialization` hands booleans out as `NSNumber` too; only the CF boolean type is a `Bool`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    /// Parses JSON text; `nil` when it is not JSON.
    public init?(json: some DataProtocol) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json), options: [.fragmentsAllowed]) else { return nil }
        self.init(any: object)
    }

    public init?(json: String) {
        self.init(json: Data(json.utf8))
    }

    /// What `JSONSerialization` writes.
    public var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.anyValue)
        case .object(let values): values.mapValues(\.anyValue)
        }
    }

    /// Compact JSON text, keys sorted.
    public var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue,
                                                     options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let values) = self, values.indices.contains(index) { return values[index] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A string that is not empty once trimmed.
    public var nonEmptyString: String? {
        guard let value = string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    public var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    public var int: Int? {
        guard let value = double, value.isFinite, abs(value) < 9e15 else { return nil }
        return Int(value)
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): value == "true" ? true : value == "false" ? false : nil
        default: nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let values) = self { return values }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// A copy small enough to travel and to keep: strings cut to `stringLimit` characters (with `…`), arrays to
    /// their first `arrayLimit` elements, anything deeper than `depth` levels replaced by `null`.
    public func clamped(stringLimit: Int, arrayLimit: Int, depth: Int) -> JSONValue {
        guard depth > 0 else { return .null }
        switch self {
        case .string(let value) where value.count > stringLimit:
            return .string(String(value.prefix(max(stringLimit - 1, 0))) + "…")
        case .array(let values):
            return .array(values.prefix(arrayLimit).map { $0.clamped(stringLimit: stringLimit, arrayLimit: arrayLimit, depth: depth - 1) })
        case .object(let values):
            return .object(values.mapValues { $0.clamped(stringLimit: stringLimit, arrayLimit: arrayLimit, depth: depth - 1) })
        default:
            return self
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}
