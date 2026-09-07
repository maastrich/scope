import Foundation

/// JSON codec configured for on-disk, human-editable files.
///
/// Output is pretty-printed with sorted keys and unescaped slashes; dates are ISO-8601.
/// `.iso8601` truncates fractional seconds, so documents whose ordering within a second matters
/// (thread records) pass `fractionalSeconds: true`; the decoder always accepts both forms.
public enum JSONStore {
    /// Encoder for a Scope document. `fractionalSeconds` keeps milliseconds in dates.
    public static func makeEncoder(fractionalSeconds: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if fractionalSeconds {
            encoder.dateEncodingStrategy = .custom { date, enc in
                var container = enc.singleValueContainer()
                try container.encode(formatMilliseconds(date))
            }
        } else {
            encoder.dateEncodingStrategy = .iso8601
        }
        return encoder
    }

    /// Decoder for a Scope document. With `fractionalSeconds` both `…:20Z` and `…:20.412Z` are accepted.
    public static func makeDecoder(fractionalSeconds: Bool = false) -> JSONDecoder {
        let decoder = JSONDecoder()
        if fractionalSeconds {
            decoder.dateDecodingStrategy = .custom { dec in
                let container = try dec.singleValueContainer()
                let text = try container.decode(String.self)
                if let date = parseFractional(text) {
                    return date
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 date: \"\(text)\"")
            }
        } else {
            decoder.dateDecodingStrategy = .iso8601
        }
        return decoder
    }

    /// `2027-01-15T08:00:01.250Z`: rounded (not truncated) to the millisecond so that a date
    /// round-trips through `parseFractional` unchanged. Foundation's fractional ISO-8601 style
    /// truncates and parses with a floating-point error, which breaks `Equatable` on decoded records.
    static func formatMilliseconds(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let whole = Date(timeIntervalSince1970: (milliseconds / 1000).rounded(.down))
        let fraction = Int(milliseconds.truncatingRemainder(dividingBy: 1000))
        return String(whole.formatted(.iso8601).dropLast()) + String(format: ".%03dZ", fraction)
    }

    /// Parses `…:20Z` and `…:20.412Z` (1 to 9 fractional digits, UTC only). `nil` for anything else.
    static func parseFractional(_ text: String) -> Date? {
        guard text.hasSuffix("Z"), let dot = text.firstIndex(of: ".") else {
            return try? Date(text, strategy: .iso8601)
        }
        let digits = text[text.index(after: dot)..<text.index(before: text.endIndex)]
        guard (1...9).contains(digits.count), digits.allSatisfy(\.isNumber),
              let whole = try? Date(String(text[..<dot]) + "Z", strategy: .iso8601),
              let fraction = Double(digits)
        else { return nil }
        return Date(timeIntervalSince1970: whole.timeIntervalSince1970 + fraction / pow(10, Double(digits.count)))
    }

    /// Atomic write: the parent directory is created if needed, then Foundation writes a temp file
    /// in the same directory and renames it over `url`.
    public static func save<T: Encodable>(_ value: T, to url: URL, fractionalSeconds: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try makeEncoder(fractionalSeconds: fractionalSeconds).encode(value)
        try data.write(to: url, options: [.atomic])
    }

    /// Reads and decodes `url`. Throws on a missing file, unreadable data or a decoding error.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, fractionalSeconds: Bool = false) throws -> T {
        try makeDecoder(fractionalSeconds: fractionalSeconds).decode(type, from: Data(contentsOf: url))
    }

    /// Moves a corrupt document out of the way without deleting it.
    ///
    /// `<dir>/config.json` becomes `<dir>/config.corrupt-2026-09-07T09-12-44Z.json` (a numeric suffix
    /// is added if that name is taken). Returns the new location so it can be shown in a `Problem`.
    @discardableResult
    public static func quarantine(_ url: URL, at date: Date = .now) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let stamp = date.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        var candidate = directory.appending(path: "\(stem).corrupt-\(stamp)\(ext)", directoryHint: .notDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(stem).corrupt-\(stamp)-\(counter)\(ext)", directoryHint: .notDirectory)
            counter += 1
        }
        try FileManager.default.moveItem(at: url, to: candidate)
        return candidate
    }
}
