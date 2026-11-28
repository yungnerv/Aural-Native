import Foundation

/// Single-process, single-writer persistence. Every mutation verifies the last
/// committed index. Unreadable data is never implicitly replaced or deleted.
actor LibraryRepository {
    private static let currentSchema = 2

    struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let tracks: [Track]
        var generation: UUID? = nil
    }

    private struct FavoriteChanges: Codable {
        var formatVersion = 1
        let baseHash: String
        var values: [UUID: Bool]

        func applying(to tracks: [Track]) -> [Track] {
            tracks.map { track in
                guard let favorite = values[track.id] else { return track }
                var updated = track
                updated.favorite = favorite
                return updated
            }
        }
    }

    struct RecoveryReport: Equatable, Sendable {
        let tracks: Int
        let missingMedia: Int
        let damagedMedia: Int
        let unverifiedMedia: Int
        let unreferencedFiles: Int
        var canRestore: Bool { missingMedia == 0 && damagedMedia == 0 }
    }

    enum Failure: LocalizedError {
        case notOpen, invalidIndex, changedOnDisk, unsupportedSchema(Int)
        case recoveryUnavailable, missingMedia, unsafeMedia, damagedMedia
        case damagedFavorites, unsupportedFavorites(Int)

        var errorDescription: String? {
            switch self {
            case .notOpen: return "Library is not open. No changes were written."
            case .invalidIndex: return "Invalid library index. Existing data is protected."
            case .changedOnDisk: return "The library index changed unexpectedly. Reopen it before modifying it."
            case .unsupportedSchema(let version): return "Unsupported library schema \(version). Existing data is protected."
            case .damagedFavorites: return "The recent favorites file is damaged."
            case .unsupportedFavorites(let version): return "Favorites format \(version) requires a different app version."
            case .recoveryUnavailable: return "There is no eligible previous index to restore."
            case .missingMedia: return "The previous index references missing or invalid files. No files have been changed."
            case .unsafeMedia: return "A media path is not a regular file. No unsafe deletion was attempted."
            case .damagedMedia: return "A previous-index media file does not match its recorded checksum. Recovery was not performed."
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
    private var favoritesURL: URL { root.appendingPathComponent(".favorite-changes.json") }
    private var damagedFavoritesIndex: Data?
    private var favoriteBytes: Data?
    private var changes: FavoriteChanges?
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
            accept(bytes, names: [])
            return []
        }
        let bytes = try readIndex(indexURL)
        let snapshot = try decode(bytes)
        do { try loadFavoriteChanges(for: bytes) }
        catch Failure.damagedFavorites {
            damagedFavoritesIndex = bytes
            throw Failure.damagedFavorites
        }
        accept(bytes, names: snapshot.names)
        return changes?.applying(to: snapshot.tracks) ?? snapshot.tracks
    }

    private func loadFavoriteChanges(for bytes: Data) throws {
        favoriteBytes = exists(favoritesURL) ? try readIndex(favoritesURL) : nil
        guard let favoriteBytes else { changes = nil; return }
        let decoder = JSONDecoder()
        guard let saved = try? decoder.decode(FavoriteChanges.self, from: favoriteBytes) else {
            struct Header: Decodable { let formatVersion: Int }
            if let header = try? decoder.decode(Header.self, from: favoriteBytes), header.formatVersion != 1 {
                throw Failure.unsupportedFavorites(header.formatVersion)
            }
            throw Failure.damagedFavorites
        }
        guard saved.formatVersion == 1 else { throw Failure.unsupportedFavorites(saved.formatVersion) }
        guard Self.validDigest(saved.baseHash) else { throw Failure.damagedFavorites }
        changes = saved.baseHash == FileDigest.sha256(bytes) ? saved : nil
    }

    /// Explicit recovery for a healthy catalog with an unreadable favorites overlay.
    func archiveDamagedFavorites() throws {
        guard !opened, let damagedFavoritesIndex, let favoriteBytes else { throw Failure.recoveryUnavailable }
        guard try readIndex(indexURL) == damagedFavoritesIndex,
              try readIndex(favoritesURL) == favoriteBytes else { throw Failure.changedOnDisk }
        let archive = root.appendingPathComponent(".favorite-changes.damaged-\(UUID().uuidString).json")
        try fm.moveItem(at: favoritesURL, to: archive)
        invalidate()
    }

    func setFavorite(_ value: Bool, id: UUID, in index: LibraryIndex) throws -> LibraryIndex {
        let base = try verifyCurrentIndex()
        guard let track = index[id] else { throw Failure.invalidIndex }
        guard track.favorite != value else { return index }
        var next = changes ?? FavoriteChanges(baseHash: FileDigest.sha256(base), values: [:])
        next.values[id] = value
        let bytes = try JSONEncoder().encode(next)
        try bytes.write(to: favoritesURL, options: .atomic)
        changes = next
        favoriteBytes = bytes
        var updated = index
        updated.setFavorite(value, id: id)
        return updated
    }

    /// Returns cleanup diagnostics separately from the committed transaction.
    /// A successful index write must never be reported as a failed commit.
    @discardableResult
    func commit(_ tracks: [Track]) throws -> [String] {
        let previous = try verifyCurrentIndex()
        let names = try Self.validatedNames(tracks)
        // A fresh generation prevents a stale sidecar from matching a later identical library.
        let bytes = try encode(tracks, generation: favoriteBytes == nil ? nil : UUID())
        guard bytes != previous else { return [] }
        var retired: [Track] = []
        var diagnostics: [String] = []
        if exists(backupURL) {
            do { retired = try decode(readIndex(backupURL)).tracks }
            catch Failure.unsupportedSchema(let version) {
                throw Failure.unsupportedSchema(version)
            }
            catch {
                diagnostics.append("Previous backup could not be read; its media will not be reclaimed: \(error.localizedDescription)")
            }
        }
        let protected = committedNames.union(names)
        let backup: Data
        if let changes {
            backup = try encode(changes.applying(to: decode(previous).tracks))
        } else {
            backup = previous
        }
        try backup.write(to: backupURL, options: .atomic)
        try bytes.write(to: indexURL, options: .atomic)
        accept(bytes, names: names)
        changes = nil
        if favoriteBytes != nil {
            do {
                try fm.removeItem(at: favoritesURL)
                favoriteBytes = nil
            } catch {
                diagnostics.append("Saved the library; retained the inactive favorites file: \(error.localizedDescription)")
            }
        }
        // A structurally valid retired index is not proof of file ownership.
        // Reclaim only app-generated names whose recorded digests still match.
        // Legacy, modified and otherwise unverified media are preserved.
        diagnostics += reclaim(retired, protecting: protected)
        return diagnostics
    }

    private func reclaim(_ tracks: [Track], protecting protected: Set<String>) -> [String] {
        var diagnostics: [String] = []
        for track in tracks {
            for media in Self.media(track, excluding: protected) {
                let url = root.appendingPathComponent(media.name)
                guard exists(url) else { continue }
                do {
                    guard isRegularFile(url) else { throw Failure.unsafeMedia }
                    guard media.managed, let expected = media.hash else {
                        diagnostics.append("Retained unverified media: \(media.name)")
                        continue
                    }
                    guard try FileDigest.sha256(url) == expected.lowercased() else {
                        diagnostics.append("Retained modified media: \(media.name)")
                        continue
                    }
                    try fm.removeItem(at: url)
                } catch {
                    diagnostics.append("Could not reclaim \(media.name): \(error.localizedDescription)")
                }
            }
        }
        return diagnostics
    }

    func makeIndex(_ tracks: [Track]) -> LibraryIndex { LibraryIndex(tracks) }

    /// Explicit recovery only. Never downgrade an unsupported newer schema or
    /// replace a healthy current index. Missing media blocks restoration.
    func inspectRecovery() throws -> RecoveryReport {
        let candidate = try recoveryCandidate()
        return try recoveryReport(for: candidate.tracks, names: candidate.names)
    }

    private func recoveryReport(for tracks: [Track], names: Set<String>) throws -> RecoveryReport {
        var missing = 0
        var damaged = 0
        var unverified = 0
        for track in tracks {
            for media in Self.media(track) {
                try Task.checkCancellation()
                let url = root.appendingPathComponent(media.name)
                guard isRegularFile(url) else {
                    missing += 1
                    continue
                }
                if let expected = media.hash {
                    do {
                        if try FileDigest.sha256(url) != expected.lowercased() { damaged += 1 }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        damaged += 1
                    }
                } else {
                    unverified += 1
                }
            }
        }
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let unreferenced = entries.filter {
            let name = $0.lastPathComponent
            let normalized = Self.key(name)
            return Self.validName(name, normalized: normalized) && !names.contains(normalized) && isRegularFile($0)
        }.count
        return RecoveryReport(tracks: tracks.count, missingMedia: missing,
                              damagedMedia: damaged, unverifiedMedia: unverified,
                              unreferencedFiles: unreferenced)
    }

    func restorePreviousIndex() throws -> [Track] {
        // Verify the exact candidate that will be written, not a second read
        // of the backup that may have changed since inspection.
        let candidate = try recoveryCandidate()
        let report = try recoveryReport(for: candidate.tracks, names: candidate.names)
        guard report.missingMedia == 0 else { throw Failure.missingMedia }
        guard report.damagedMedia == 0 else { throw Failure.damagedMedia }
        try Task.checkCancellation()
        // Preserve corrupt bytes in a unique recovery file before replacing the
        // index. The backup is not consumed and unknown files remain untouched.
        if let damaged = candidate.damaged {
            let archive = root.appendingPathComponent("library.damaged-\(UUID().uuidString).json")
            try damaged.write(to: archive, options: .atomic)
        }
        let current = exists(indexURL) ? try readIndex(indexURL) : nil
        guard current == candidate.damaged,
              try readIndex(backupURL) == candidate.backup else { throw Failure.changedOnDisk }
        // Read and validate the sidecar before replacing a damaged index.
        try loadFavoriteChanges(for: candidate.backup)
        let restored = changes?.applying(to: candidate.tracks) ?? candidate.tracks
        let bytes = try encode(restored, generation: favoriteBytes == nil ? nil : UUID())
        try bytes.write(to: indexURL, options: .atomic)
        accept(bytes, names: candidate.names)
        changes = nil
        return restored
    }

    private func recoveryCandidate() throws -> (tracks: [Track], names: Set<String>, damaged: Data?, backup: Data) {
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
        let snapshot = try decode(backup)
        return (snapshot.tracks, snapshot.names, damaged, backup)
    }

    private func accept(_ bytes: Data, names: Set<String>) {
        previousBytes = bytes
        committedNames = names
        opened = true
    }

    private func invalidate() {
        opened = false
        damagedFavoritesIndex = nil
        previousBytes = nil
        committedNames.removeAll()
        favoriteBytes = nil
        changes = nil
    }

    private func encode(_ tracks: [Track], generation: UUID? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Snapshot(schemaVersion: Self.currentSchema, tracks: tracks, generation: generation))
    }

    private func decode(_ bytes: Data) throws -> (tracks: [Track], names: Set<String>) {
        let decoder = JSONDecoder()
        let tracks: [Track]
        if let snapshot = try? decoder.decode(Snapshot.self, from: bytes) {
            guard (1...Self.currentSchema).contains(snapshot.schemaVersion) else { throw Failure.unsupportedSchema(snapshot.schemaVersion) }
            tracks = snapshot.tracks
        } else if let legacy = try? decoder.decode([Track].self, from: bytes) {
            tracks = legacy
        } else {
            // Detect even a newer envelope whose Track schema cannot be decoded.
            if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               let version = object["schemaVersion"] as? Int, !(1...Self.currentSchema).contains(version) {
                throw Failure.unsupportedSchema(version)
            }
            throw Failure.invalidIndex
        }
        return (tracks, try Self.validatedNames(tracks))
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
            let onDiskFavorites = exists(favoritesURL) ? try readIndex(favoritesURL) : nil
            guard onDiskFavorites == favoriteBytes, try readIndex(indexURL) == previousBytes else { throw Failure.changedOnDisk }
            return previousBytes
        } catch {
            invalidate()
            throw Failure.changedOnDisk
        }
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func validName(_ name: String, normalized: String) -> Bool {
        return !name.isEmpty && !name.hasPrefix(".") &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
            normalized != "library.json" && normalized != "library.previous.json" &&
            !normalized.hasPrefix("library.damaged-")
    }

    private struct MediaReference {
        let name: String
        let hash: String?
        let managed: Bool
    }

    private static func media(_ track: Track, excluding protected: Set<String> = []) -> [MediaReference] {
        var result: [MediaReference] = []
        if !protected.contains(key(track.file)) {
            let stem = URL(fileURLWithPath: track.file).deletingPathExtension().lastPathComponent
            result.append(MediaReference(name: track.file, hash: track.contentHash,
                                         managed: key(stem) == key(track.id.uuidString)))
        }
        if let artwork = track.artwork {
            let normalized = key(artwork)
            if !protected.contains(normalized) {
                result.append(MediaReference(name: artwork, hash: track.artworkHash,
                                             managed: normalized == "\(key(track.id.uuidString))-cover.jpg"))
            }
        }
        return result
    }

    private static func validDigest(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func validatedNames(_ tracks: [Track]) throws -> Set<String> {
        var ids = Set<UUID>()
        var names = Set<String>()
        ids.reserveCapacity(tracks.count)
        names.reserveCapacity(tracks.count)
        func insert(_ name: String) throws {
            let normalized = key(name)
            guard validName(name, normalized: normalized), names.insert(normalized).inserted else {
                throw Failure.invalidIndex
            }
        }
        for track in tracks {
            guard ids.insert(track.id).inserted, track.duration.isFinite, track.duration >= 0,
                  validDigest(track.contentHash), validDigest(track.artworkHash),
                  track.artwork != nil || track.artworkHash == nil,
                  track.metadata?.track?.isValid ?? true, track.metadata?.disc?.isValid ?? true else {
                throw Failure.invalidIndex
            }
            try insert(track.file)
            if let artwork = track.artwork { try insert(artwork) }
        }
        return names
    }

    /// Roll back unpublished imports under the same ownership rules as retired media.
    func discardImports(_ tracks: [Track]) throws -> [String] {
        _ = try verifyCurrentIndex()
        let names = try Self.validatedNames(tracks)
        guard names.isDisjoint(with: committedNames) else { throw Failure.invalidIndex }
        let backupNames = exists(backupURL) ? try decode(readIndex(backupURL)).names : []
        for track in tracks {
            for media in Self.media(track, excluding: backupNames) {
                let url = root.appendingPathComponent(media.name)
                guard !exists(url) || isRegularFile(url) else { throw Failure.unsafeMedia }
            }
        }
        return reclaim(tracks, protecting: backupNames)
    }
}
