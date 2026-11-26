import Foundation

/// The sole writer of the library index. Legacy arrays are read without changing
/// the original until a successful commit. A damaged index blocks all mutations.
actor LibraryRepository {
    struct Snapshot: Codable {
        let schemaVersion: Int
        let tracks: [Track]
    }
    enum Failure: LocalizedError {
        case notOpen, invalidIndex, unsupportedSchema(Int)
        var errorDescription: String? {
            switch self {
            case .notOpen: return "Library is not open. No changes were written."
            case .invalidIndex: return "Invalid library index. Existing data is protected."
            case .unsupportedSchema(let version): return "Unsupported library schema \(version). Existing data is protected."
            }
        }
    }

    nonisolated let root: URL
    private let fm = FileManager.default
    private var opened = false
    private var previousBytes: Data?
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    private var backupURL: URL { root.appendingPathComponent("library.previous.json") }

    init(root: URL) { self.root = root }

    func load() throws -> [Track] {
        opened = false
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: indexURL.path) else {
            if fm.fileExists(atPath: backupURL.path) { throw Failure.invalidIndex }
            previousBytes = nil
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
        opened = true
        return tracks
    }

    func commit(_ tracks: [Track]) throws {
        guard opened else { throw Failure.notOpen }
        try Self.validate(tracks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Snapshot(schemaVersion: 1, tracks: tracks))
        if let previousBytes { try previousBytes.write(to: backupURL, options: .atomic) }
        try bytes.write(to: indexURL, options: .atomic)
        previousBytes = bytes
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
        for name in [track.file, track.artwork].compactMap({ $0 }) {
            guard Self.validName(name) else { throw Failure.invalidIndex }
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }
}
