import Foundation
import Testing
@testable import ScopeCore

private struct Sample: Codable, Equatable {
    var zeta: String
    var alpha: Int
    var url: String
    var when: Date
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "scope-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct JSONStoreTests {
    @Test func sortedKeysAndUnescapedSlashes() throws {
        let value = Sample(zeta: "z", alpha: 1, url: "https://x/y", when: Date(timeIntervalSince1970: 1_700_000_000))
        let text = String(decoding: try JSONStore.makeEncoder().encode(value), as: UTF8.self)
        #expect(text.contains("https://x/y"))
        #expect(!text.contains("\\/"))
        let alpha = try #require(text.range(of: "\"alpha\""))
        let url = try #require(text.range(of: "\"url\""))
        let when = try #require(text.range(of: "\"when\""))
        let zeta = try #require(text.range(of: "\"zeta\""))
        #expect(alpha.lowerBound < url.lowerBound)
        #expect(url.lowerBound < when.lowerBound)
        #expect(when.lowerBound < zeta.lowerBound)
        #expect(text.contains("\n"))   // pretty printed
    }

    @Test func plainDatesDropFractionalSeconds() throws {
        let value = Sample(zeta: "", alpha: 0, url: "", when: Date(timeIntervalSince1970: 1_700_000_000.5))
        let data = try JSONStore.makeEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self).contains("\"2023-11-14T22:13:20Z\""))
        let decoded = try JSONStore.makeDecoder().decode(Sample.self, from: data)
        #expect(decoded.when == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func fractionalDatesRoundTrip() throws {
        let value = Sample(zeta: "", alpha: 0, url: "", when: Date(timeIntervalSince1970: 1_700_000_000.5))
        let data = try JSONStore.makeEncoder(fractionalSeconds: true).encode(value)
        #expect(String(decoding: data, as: UTF8.self).contains("\"2023-11-14T22:13:20.500Z\""))
        let decoded = try JSONStore.makeDecoder(fractionalSeconds: true).decode(Sample.self, from: data)
        #expect(decoded == value)
    }

    @Test func fractionalDecoderAcceptsBothForms() throws {
        let json = Data(#"{"alpha":0,"url":"","when":"2023-11-14T22:13:20Z","zeta":""}"#.utf8)
        let decoded = try JSONStore.makeDecoder(fractionalSeconds: true).decode(Sample.self, from: json)
        #expect(decoded.when == Date(timeIntervalSince1970: 1_700_000_000))

        let bad = Data(#"{"alpha":0,"url":"","when":"yesterday","zeta":""}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONStore.makeDecoder(fractionalSeconds: true).decode(Sample.self, from: bad)
        }
    }

    @Test func saveIsAtomicAndCreatesDirectories() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "nested/deeper/doc.json")
        let value = Sample(zeta: "z", alpha: 7, url: "/a/b", when: Date(timeIntervalSince1970: 1_700_000_000))

        try JSONStore.save(value, to: file)
        try JSONStore.save(value, to: file)   // overwrite in place

        let siblings = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(siblings == ["doc.json"])     // no temp file left behind
        #expect(try JSONStore.load(Sample.self, from: file) == value)
    }

    @Test func loadOfMissingFileThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try JSONStore.load(Sample.self, from: dir.appending(path: "missing.json"))
        }
    }

    @Test func quarantineRenamesNextToTheOriginal() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data("{ broken".utf8).write(to: file)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        let backup = try JSONStore.quarantine(file, at: stamp)
        #expect(backup.lastPathComponent == "config.corrupt-2023-11-14T22-13-20Z.json")
        #expect(backup.deletingLastPathComponent().path == dir.path)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(String(decoding: try Data(contentsOf: backup), as: UTF8.self) == "{ broken")

        // Same stem and stamp again → numeric suffix, nothing overwritten.
        try Data("{ broken again".utf8).write(to: file)
        let second = try JSONStore.quarantine(file, at: stamp)
        #expect(second.lastPathComponent == "config.corrupt-2023-11-14T22-13-20Z-2.json")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
}
