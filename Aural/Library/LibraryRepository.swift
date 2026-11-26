import Foundation

/// Single-process, single-writer persistence. Every mutation verifies the last
/// committed index. Unreadable data is never implicitly replaced or deleted.
actor LibraryRepository {
    struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let tracks: [Track]
    }

    struct RecoveryReport: Equatable, Sendable {
        let tracks: Int
        let missingMedia: Int
        let unreferencedFiles: Int
        var canRestore: Bool { missingMedia == 0 }
    }

    enum Failure: LocalizedError {
        case notOpen, invalidIndex, changedOnDisk, unsupportedSchema(Int)
        case recoveryUnavailable, missingMedia, unsafeMedia

        var errorDescription: String? {
            switch self {
            case .notOpen: return "Library is not open. No changes were written."
            case .invalidIndex: return "Invalid library index. Existing data is protected."
            case .changedOnDisk: return "The library index changed unexpectedly. Reopen it before modifying it."
            case .unsupportedSchema(let version): return "Unsupported library schema \(version). Existing data is protected."
            case .recoveryUnavailable: return "There is no eligible previous index to restore."
            case .missingMedia: return "The previous index references missing or invalid files. No files have been changed."
            case .unsafeMedia: return "A media path is not a regular file. No unsafe deletion was attempted."
            }
        }

        var requiresReopen: Bool {
            switch self {
            case .notOpen, .changedOnDisk: return true
            default: return false
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
        invalidate()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if !exists(indexURL) {
            // Existing files without an index indicate a recovery condition.
            // Only a genuinely empty directory may receive an empty index.
            guard try fm.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw Failure.invalidIndex
            }
            let bytes = try encode([])
            // The actor is the sole writer. Atomic replacement prevents a partial
            // initial index after an interruption; never initialize over media.
            try bytes.write(to: indexURL, options: .atomic)
            accept(bytes, tracks: [])
            return []
        }
        let bytes = try readIndex(indexURL)
        let tracks = try decode(bytes)
        accept(bytes, tracks: tracks)
        return tracks
    }

    func commit(_ tracks: [Track]) throws {
        let previous = try verifyCurrentIndex()
        try Self.validate(tracks)
        let bytes = try encode(tracks)
        guard bytes != previous else { return }
        try previous.write(to: backupURL, options: .atomic)
        try bytes.write(to: indexURL, options: .atomic)
        accept(bytes, tracks: tracks)
    }

    func makeIndex(_ tracks: [Track]) -> LibraryIndex { LibraryIndex(tracks) }

    /// Explicit recovery only. Never downgrade an unsupported newer schema or
    /// replace a healthy current index. Missing media blocks restoration.
    func inspectRecovery() throws -> RecoveryReport {
        let candidate = try recoveryCandidate()
        let names = Self.names(candidate.tracks)
        let missing = candidate.tracks.flatMap { [$0.file, $0.artwork].compactMap { $0 } }
            .filter { !isRegularFile(root.appendingPathComponent($0)) }.count
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let unreferenced = entries.filter {
            Self.validName($0.lastPathComponent) && !names.contains(Self.key($0.lastPathComponent)) && isRegularFile($0)
        }.count
        return RecoveryReport(tracks: candidate.tracks.count, missingMedia: missing, unreferencedFiles: unreferenced)
    }

    func restorePreviousIndex() throws -> [Track] {
        let candidate = try recoveryCandidate()
        let report = try inspectRecovery()
        guard report.canRestore else { throw Failure.missingMedia }
        // Preserve corrupt bytes in a unique recovery file before replacing the
        // index. The backup is not consumed and unknown files remain untouched.
        if let damaged = candidate.damaged {
            let archive = root.appendingPathComponent("library.damaged-\(UUID().uuidString).json")
            try damaged.write(to: archive, options: .atomic)
        }
        let current = exists(indexURL) ? try readIndex(indexURL) : nil
        guard current == candidate.damaged,
              try readIndex(backupURL) == candidate.backup else { throw Failure.changedOnDisk }
        let bytes = try encode(candidate.tracks)
        try bytes.write(to: indexURL, options: .atomic)
        accept(bytes, tracks: candidate.tracks)
        return candidate.tracks
    }

    private func recoveryCandidate() throws -> (tracks: [Track], damaged: Data?, backup: Data) {
        guard !opened else { throw Failure.recoveryUnavailable }
        let damaged = exists(indexURL) ? try readIndex(indexURL) : nil
        if let damaged {
            do {
                _ = try decode(damaged)
                throw Failure.recoveryUnavailable
            } catch Failure.invalidIndex {
                // Corruption, rather than an unsupported schema or healthy index.
            }
        }
        guard exists(backupURL) else { throw Failure.recoveryUnavailable }
        let backup = try readIndex(backupURL)
        return (try decode(backup), damaged, backup)
    }

    private func accept(_ bytes: Data, tracks: [Track]) {
        previousBytes = bytes
        committedNames = Self.names(tracks)
        opened = true
    }

    private func invalidate() {
        opened = false
        previousBytes = nil
        committedNames.removeAll()
    }

    private func encode(_ tracks: [Track]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Snapshot(schemaVersion: 1, tracks: tracks))
    }

    private func decode(_ bytes: Data) throws -> [Track] {
        let decoder = JSONDecoder()
        let tracks: [Track]
        if let snapshot = try? decoder.decode(Snapshot.self, from: bytes) {
            guard snapshot.schemaVersion == 1 else { throw Failure.unsupportedSchema(snapshot.schemaVersion) }
            tracks = snapshot.tracks
        } else if let legacy = try? decoder.decode([Track].self, from: bytes) {
            tracks = legacy
        } else {
            // Detect even a newer envelope whose Track schema cannot be decoded.
            if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let version = object["schemaVersion"] as? Int, version != 1 {
                throw Failure.unsupportedSchema(version)
            }
            throw Failure.invalidIndex
        }
        try Self.validate(tracks)
        return tracks
    }

    private func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func readIndex(_ url: URL) throws -> Data {
        guard isRegularFile(url) else { throw Failure.invalidIndex }
        return try Data(contentsOf: url)
    }

    private func verifyCurrentIndex() throws -> Data {
        guard opened, let previousBytes else { throw Failure.notOpen }
        do {
            guard try readIndex(indexURL) == previousBytes else { throw Failure.changedOnDisk }
            return previousBytes
        } catch {
            invalidate()
            throw Failure.changedOnDisk
        }
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func names(_ tracks: [Track]) -> Set<String> {
        Set(tracks.flatMap { [$0.file, $0.artwork].compactMap { $0 } }.map(key))
    }

    private static func validName(_ name: String) -> Bool {
        let normalized = key(name)
        return !name.isEmpty && !name.hasPrefix(".") &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
            normalized != "library.json" && normalized != "library.previous.json" &&
            !normalized.hasPrefix("library.damaged-")
    }

    private static func validate(_ tracks: [Track]) throws {
        let names = tracks.flatMap { [$0.file, $0.artwork].compactMap { $0 } }
        guard Set(tracks.map(\.id)).count == tracks.count,
              Set(names.map(key)).count == names.count,
              names.allSatisfy(validName),
              tracks.allSatisfy({ $0.duration.isFinite && $0.duration >= 0 }) else {
            throw Failure.invalidIndex
        }
    }

    /// Preflight every path before touching any file. The stale-index guard is
    /// deliberately independent from commit(), including rollback/cleanup paths.
    func removeMedia(_ track: Track) throws {
        _ = try verifyCurrentIndex()
        let names = [track.file, track.artwork].compactMap { $0 }
        guard names.allSatisfy({ Self.validName($0) && !committedNames.contains(Self.key($0)) }) else {
            throw Failure.invalidIndex
        }
        let urls = names.map { root.appendingPathComponent($0) }
        guard urls.allSatisfy({ !exists($0) || isRegularFile($0) }) else { throw Failure.unsafeMedia }
        for url in urls where exists(url) { try fm.removeItem(at: url) }
    }
}
