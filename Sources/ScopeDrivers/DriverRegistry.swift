import Foundation
import ScopeCore

/// The profiles available to the app after merging bundled and user files.
public struct LoadedDrivers: Sendable {
    /// Sorted: `shell` first, then by name.
    public var profiles: [DriverProfile]
    /// Unreadable or invalid user files. When such a file shadows a bundled id, the bundled profile is used.
    public var problems: [StoreProblem]

    public init(profiles: [DriverProfile], problems: [StoreProblem] = []) {
        self.profiles = profiles
        self.problems = problems
    }

    /// The profile with this id, if any.
    public func profile(id: String) -> DriverProfile? {
        profiles.first { $0.id == id }
    }
}

/// Loads driver profiles: the ones bundled with the app (`Builtin/*.json`, via `Bundle.module`) and the
/// user's `<home>/drivers/*.json`. User files win over bundled ones with the same id when they validate.
public actor DriverRegistry {
    /// Subdirectory of the resource bundle holding the bundled profiles.
    public static let bundledSubdirectory = "Builtin"

    /// The resource bundle shipping the bundled profiles (`Bundle.module`, which SwiftPM keeps internal).
    public static var builtinBundle: Bundle { .module }

    private let driversDirectory: URL
    private let bundledURLs: [URL]
    private var cache: LoadedDrivers?

    /// - Parameters:
    ///   - home: `SCOPE_HOME`; profiles are read from and installed into `<home>/drivers`.
    ///   - bundle: where the bundled profiles live (`Bundle.module` in the app and tests).
    public init(home: URL, bundle: Bundle = DriverRegistry.builtinBundle) {
        driversDirectory = ScopeHome.driversURL(home: home)
        bundledURLs = Self.bundledURLs(in: bundle)
    }

    /// The four bundled profiles, decoded and validated. Throws on a malformed bundled file (a packaging bug).
    public static func bundledProfiles(bundle: Bundle = DriverRegistry.builtinBundle) throws -> [DriverProfile] {
        try bundledURLs(in: bundle).map { try decode(at: $0) }
    }

    /// Installs the bundled profiles into `<home>/drivers/<id>.json`:
    ///
    /// - a missing file is copied;
    /// - an existing file is **replaced** only when it is an untouched older bundled copy: it decodes, still says
    ///   `"builtin": true`, and its `version` is lower than the bundled one. A user edit that drops or changes
    ///   `builtin` / `version`, or an unreadable file, is left alone.
    ///
    /// Returns the ids installed or upgraded by this call.
    @discardableResult
    public func installBuiltins() async throws -> [String] {
        try FileManager.default.createDirectory(at: driversDirectory, withIntermediateDirectories: true)
        var installed: [String] = []
        for url in bundledURLs {
            let profile = try Self.decode(at: url)
            let destination = driversDirectory.appending(path: "\(profile.id).json")
            if FileManager.default.fileExists(atPath: destination.path) {
                guard Self.isStaleBuiltinCopy(at: destination, bundled: profile) else { continue }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            installed.append(profile.id)
        }
        if !installed.isEmpty { cache = nil }
        return installed
    }

    /// `true` when the file at `url` is a bundled copy (`builtin == true`) older than `bundled.version`.
    static func isStaleBuiltinCopy(at url: URL, bundled: DriverProfile) -> Bool {
        guard let existing = try? JSONStore.load(DriverProfile.self, from: url), existing.builtin == true else { return false }
        return (existing.version ?? 0) < (bundled.version ?? 0)
    }

    /// Bundled profiles overlaid with the user's valid files. Cached after the first call; see `reload()`.
    public func load() async -> LoadedDrivers {
        if let cache { return cache }
        return await reload()
    }

    /// Re-reads `<home>/drivers` and replaces the cache.
    public func reload() async -> LoadedDrivers {
        let loaded = Self.merge(bundledURLs: bundledURLs, driversDirectory: driversDirectory)
        cache = loaded
        return loaded
    }

    // MARK: - Internals

    private static func bundledURLs(in bundle: Bundle) -> [URL] {
        let urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: bundledSubdirectory) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func decode(at url: URL) throws -> DriverProfile {
        let profile = try JSONStore.load(DriverProfile.self, from: url)
        try profile.validate()
        return profile
    }

    /// Pure merge of bundled + user files. Static so it never touches actor state while doing I/O.
    static func merge(bundledURLs: [URL], driversDirectory: URL) -> LoadedDrivers {
        var byID: [String: DriverProfile] = [:]
        var problems: [StoreProblem] = []

        for url in bundledURLs {
            do {
                let profile = try decode(at: url)
                byID[profile.id] = profile
            } catch {
                problems.append(StoreProblem(file: url, message: "Bundled driver profile is invalid: \(describe(error))"))
            }
        }

        for url in userProfileURLs(in: driversDirectory) {
            let expectedID = url.deletingPathExtension().lastPathComponent
            do {
                let profile = try decode(at: url)
                guard profile.id == expectedID else {
                    problems.append(StoreProblem(
                        file: url,
                        message: "Driver id \"\(profile.id)\" does not match the file name; rename the file to \(profile.id).json."
                    ))
                    continue
                }
                byID[profile.id] = profile
            } catch {
                let fallback = byID[expectedID] != nil ? " Using the bundled \"\(expectedID)\" profile instead." : ""
                problems.append(StoreProblem(file: url, message: "\(describe(error))\(fallback)"))
            }
        }

        let profiles = byID.values.sorted { lhs, rhs in
            if lhs.id == "shell" { return rhs.id != "shell" }
            if rhs.id == "shell" { return false }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
        return LoadedDrivers(profiles: profiles, problems: problems)
    }

    /// `*.json` files (not hidden) in the drivers directory, sorted by name. A missing directory yields `[]`.
    private static func userProfileURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? DriverProfileError { return error.description }
        if let error = error as? DecodingError { return describe(error) }
        return String(describing: error)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).joined(separator: ".")
            return keys.isEmpty ? "" : " at \"\(keys)\""
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing key \"\(key.stringValue)\"\(path(context))."
        case .typeMismatch(_, let context):
            return "Wrong value type\(path(context)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "Missing value\(path(context))."
        case .dataCorrupted(let context):
            return "Not valid JSON: \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
