import Foundation

/// Stable identity of a declared scope.
///
/// Serialised as a plain lowercase UUID string (`"8d0c1f9e-4b6a-4c62-9c3f-2d1e7a5b9f10"`),
/// which is what `config.json` and every `threads/<id>.json` carry.
public struct ScopeID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Lowercase UUID string.
    public let rawValue: String

    /// Wraps an existing identifier. The value is lowercased so two spellings of the same UUID compare equal.
    public init(rawValue: String) {
        self.rawValue = rawValue.lowercased()
    }

    /// A fresh random identifier.
    public static func generate() -> ScopeID {
        ScopeID(rawValue: UUID().uuidString)
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Identity of a thread: 12 lowercase hex characters (48 random bits), e.g. `"3f9a2c17be04"`.
///
/// The value is used verbatim as the record file name (`threads/<id>.json`) and as the
/// `SCOPE_THREAD` environment variable, so it is validated on every construction and never
/// contains anything that would need quoting.
public struct ThreadID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    /// Exactly 12 characters in `0-9a-f`.
    public let rawValue: String

    /// Returns `nil` unless `rawValue` matches `^[0-9a-f]{12}$`.
    public init?(rawValue: String) {
        guard ThreadID.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(validated: String) {
        rawValue = validated
    }

    /// A fresh random identifier (48 bits from the system RNG).
    public static func generate() -> ThreadID {
        let bits = UInt64.random(in: 0...0xFFFF_FFFF_FFFF)
        let hex = String(bits, radix: 16)
        let padded = String(repeating: "0", count: max(0, 12 - hex.count)) + hex
        return ThreadID(validated: padded)
    }

    /// `true` when `candidate` is 12 lowercase hex characters.
    public static func isValid(_ candidate: String) -> Bool {
        let bytes = candidate.utf8
        guard bytes.count == 12 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: ThreadID, rhs: ThreadID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = ThreadID(rawValue: text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Thread id must be 12 lowercase hex characters, got \"\(text)\""
            )
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
