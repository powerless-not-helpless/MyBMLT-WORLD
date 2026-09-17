import Foundation

/// Typed JSON persistence in Application Support.
///
/// Chosen over SwiftData/Core Data deliberately: the largest collection here is
/// ~1,571 service bodies read weekly, and the rest are `Set<String>` of a few
/// hundred identifiers. A schema and migration story would cost more than the
/// ~60 lines this replaces.
///
/// `nonisolated` on purpose. This type does file I/O and holds no UI state, so
/// it has no reason to be main-actor-bound. Without this it is *inferred* as
/// main-actor-isolated from the `@MainActor` stores that own it, which makes
/// every default argument like `FileStore()` a nonisolated-context error — six
/// of them existed, each warning that it "is an error in the Swift 6 language
/// mode". Marking the type accurately is the fix, not annotating each caller.
nonisolated struct FileStore {

    static let directoryName = "MyBMLT"

    let directory: URL

    init(subdirectory: String? = nil) {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        self.directory = subdirectory.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Points the store at an arbitrary directory.
    ///
    /// Exists so tests never touch Application Support. Test-only in intent,
    /// but not `#if DEBUG`-gated, because the test target in a Release-tested
    /// build must still compile.
    init(testDirectory: URL) {
        self.directory = testDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // MARK: - Codable

    func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    @discardableResult
    func write<T: Encodable>(_ value: T, to name: String, protected: Bool = false) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url(for: name), options: [.atomic])
            if protected {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url(for: name).path
                )
            }
            return true
        } catch {
            #if DEBUG
            print("[FileStore] write failed for \(name): \(error)")
            #endif
            return false
        }
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    func modifiedAt(_ name: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: name).path)
        return attrs?[.modificationDate] as? Date
    }
}

/// Cache freshness policy, kept in one place so TTLs are arguable rather than
/// scattered through call sites.
enum CachePolicy {
    /// The service body graph changes very rarely.
    static let serviceBodies: TimeInterval = 7 * 24 * 60 * 60
    /// Meeting lists are stale-while-revalidate, so age never blocks display.
    static let meetings: TimeInterval = 6 * 60 * 60

    static func isFresh(_ date: Date?, within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < interval
    }

    /// Rounds coordinates for cache keys so a jittering GPS fix doesn't create
    /// a new cache entry every few seconds. 3 dp ≈ 110 m.
    static func geoKey(latitude: Double, longitude: Double, radiusMiles: Double) -> String {
        String(format: "%.3f_%.3f_%.0f", latitude, longitude, radiusMiles)
    }
}
