import Foundation

/// The sole writer of the library index. Legacy arrays are read without changing
/// the original until a successful commit. A damaged index blocks all mutations.
actor LibraryRepository {
    struct Snapshot: Codable {
        let schemaVersion: Int
        let tracks: [Track]
    }
    enum Failure: LocalizedError {
        case notOpen, invalidIndex, changedOnDisk, unsupportedSchema(Int)
        var errorDescription: String? {
            switch self {
            case .notOpen: return "Library is not open. No changes were written."
            case .invalidIndex: return "Invalid library index. Existing data is protected."
            case .changedOnDisk: return "The library index changed unexpectedly. Reopen the library before modifying it."
            case .unsupportedSchema(let version): return "Unsupported library schema \(version). Existing data is protected."
            }
        }
    }

    nonisolated let root: URL
    private let fm = FileManager.default
    private var opened = false
    private var previousBytes: Data?
    private var committedNames = Set<String>()
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    private var backupURL: URL { root.appendingPathComponent("library.previous.json") }

    init(root: URL) { self.root = root }

    func load() throws -> [Track] {
        opened = false
        previousBytes = nil
        committedNames.removeAll()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: indexURL.path) else {
            // Missing index plus existing media is not a new empty library.
            let existing = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            if !existing.isEmpty { throw Failure.invalidIndex }
            // Establish an empty index before allowing the first import. A crash
            // while copying that first file must not make the library look lost.
            let bytes = try encode([])
            try bytes.write(to: indexURL, options: [.withoutOverwriting])
            previousBytes = bytes
            opened = true
            return []
        }
        let bytes = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        let tracks: [Track]
        if let snapshot = try? decoder.decode(Snapshot.self, from: bytes) {
            guard snapshot.schemaVersion == 1 else { throw Failure.unsupportedSchema(snapshot.schemaVersion) }
            tracks = snapshot.tracks
        } else if let legacy = try? decoder.decode([Track].self, from: bytes) {
            tracks = legacy
        } else { throw Failure.invalidIndex }
        try Self.validate(tracks)
        previousBytes = bytes
        committedNames = Self.names(tracks)
        opened = true
        return tracks
    }

    func commit(_ tracks: [Track]) throws {
        let previous = try verifyCurrentIndex()
        try Self.validate(tracks)
        let bytes = try encode(tracks)
        try previous.write(to: backupURL, options: .atomic)
        try bytes.write(to: indexURL, options: .atomic)
        previousBytes = bytes
        committedNames = Self.names(tracks)
    }

    private func encode(_ tracks: [Track]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Snapshot(schemaVersion: 1, tracks: tracks))
    }

    /// Fail closed if another writer or an external recovery changed the index
    /// since it was opened. Never back up or overwrite unexpected disk contents.
    private func verifyCurrentIndex() throws -> Data {
        guard opened, let previousBytes else { throw Failure.notOpen }
        do {
            guard try Data(contentsOf: indexURL) == previousBytes else {
                throw Failure.changedOnDisk
            }
            return previousBytes
        } catch {
            opened = false
            throw Failure.changedOnDisk
        }
    }

    func makeIndex(_ tracks: [Track]) -> LibraryIndex { LibraryIndex(tracks) }

    private static func names(_ tracks: [Track]) -> Set<String> {
        Set(tracks.flatMap { [$0.file, $0.artwork].compactMap { $0 } })
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
        !["library.json", "library.previous.json"].contains(name.lowercased())
    }

    private static func validate(_ tracks: [Track]) throws {
        let names = tracks.flatMap { [$0.file, $0.artwork].compactMap { $0 } }
        guard Set(tracks.map(\.id)).count == tracks.count,
              Set(names).count == names.count,
              names.allSatisfy(validName),
              tracks.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 }) else {
            throw Failure.invalidIndex
        }
    }

    /// Called only after an index deletion commits or an uncommitted import fails.
    func removeMedia(_ track: Track) throws {
        guard opened else { throw Failure.notOpen }
        let names = [track.file, track.artwork].compactMap { $0 }
        guard names.allSatisfy({ Self.validName($0) && !committedNames.contains($0) }) else { throw Failure.invalidIndex }
        for name in names {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }
}
