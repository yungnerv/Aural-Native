import Foundation
import Combine

/// Main-actor coordinator. The repository owns persistence, the importer owns file
/// inspection, and the playback engine and system bridge own platform integration.
@MainActor final class MusicStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var libraryReady = false
    @Published private(set) var libraryLoading = true
    @Published private(set) var mutationBusy = false
    @Published private(set) var currentID: UUID?
    @Published private(set) var playing = false
    @Published private(set) var importing = false
    @Published var message: String?
    @Published private(set) var shuffle = false
    @Published var repeatOne = false

    let clock = PlaybackClock()
    private(set) var index = LibraryIndex([])
    private let repository: LibraryRepository
    private let importer = AudioImporter()
    private let engine = PlaybackEngine()
    private var system: NowPlayingController?
    private let root: URL
    private var queue = PlaybackQueue()
    private var actualPlaying = false
    var current: Track? { currentID.flatMap { index.byID[$0] } }

    private var elapsed: Double {
        get { clock.elapsed }
        set { if clock.elapsed != newValue { clock.elapsed = newValue } }
    }
    private var duration: Double {
        get { clock.duration }
        set { if clock.duration != newValue { clock.duration = newValue } }
    }

    init() {
        root = URL.applicationSupportDirectory.appendingPathComponent("AuralLibrary", isDirectory: true)
        repository = LibraryRepository(root: root)
        engine.onProgress = { [weak self] elapsed, duration in
            guard let self, self.currentID != nil else { return }
            self.elapsed = elapsed
            if let duration, self.duration != duration {
                self.duration = duration
                self.updateSystem()
            }
        }
        engine.onState = { [weak self] wanted, audible in
            guard let self else { return }
            if self.playing != wanted { self.playing = wanted }
            if self.actualPlaying != audible {
                self.actualPlaying = audible
                self.updateSystem()
            }
        }
        engine.onEnd = { [weak self] in
            guard let self else { return }
            if self.repeatOne {
                self.elapsed = 0
                self.engine.seek(0, resumeAfterSeek: true)
                self.updateSystem()
            } else { self.advance(1, automatic: true) }
        }
        engine.onFailure = { [weak self] message in self?.message = message }
        engine.onSeek = { [weak self] in self?.updateSystem() }
        system = NowPlayingController(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.engine.pause() },
            next: { [weak self] in self?.advance(1) },
            previous: { [weak self] in self?.advance(-1) },
            seek: { [weak self] in self?.seek($0) }
        )
        Task { [weak self] in await self?.openLibrary() }
    }

    private func openLibrary() async {
        defer { libraryLoading = false }
        do {
            await apply(try await repository.load())
            libraryReady = true
        } catch {
            message = "Library could not be opened. Existing files are protected.\n\(error.localizedDescription)"
        }
    }

    private func apply(_ next: [Track]) async {
        index = await repository.makeIndex(next)
        tracks = next
    }

    private func commit(_ next: [Track]) async throws {
        try await repository.commit(next)
        await apply(next)
    }

    func artworkURL(_ track: Track) -> URL? {
        track.artwork.map { root.appendingPathComponent($0) }
    }

    func importFiles(_ urls: [URL]) async {
        guard libraryReady, !mutationBusy else { return }
        importing = true
        mutationBusy = true
        defer { importing = false; mutationBusy = false }
        var next = tracks
        var pending: [Track] = []
        var hashes = Set(next.compactMap(\.contentHash))
        var errors: [String] = []
        var duplicates = 0
        do {
            for i in next.indices where next[i].contentHash == nil {
                try Task.checkCancellation()
                do {
                    let digest = try await importer.digest(root.appendingPathComponent(next[i].file))
                    next[i].contentHash = digest
                    hashes.insert(digest)
                } catch is CancellationError { throw CancellationError() }
                catch { errors.append("Could not verify \(next[i].title): \(error.localizedDescription)") }
            }
            for url in urls {
                try Task.checkCancellation()
                do {
                    if let track = try await importer.readFile(url, into: root, knownHashes: hashes) {
                        pending.append(track)
                        next.append(track)
                        if let hash = track.contentHash { hashes.insert(hash) }
                    } else { duplicates += 1 }
                } catch is CancellationError { throw CancellationError() }
                catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                if pending.count >= 16 {
                    try await commit(next)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if next != tracks { try await commit(next) }
            pending.removeAll()
        } catch {
            for track in pending {
                do { try await repository.removeMedia(track) }
                catch { errors.append("Could not clean up \(track.title): \(error.localizedDescription)") }
            }
            errors.append(error.localizedDescription)
        }
        if duplicates > 0 { errors.append("\(duplicates) duplicate file(s) skipped.") }
        if !errors.isEmpty { message = errors.joined(separator: "\n") }
    }

    func play(_ track: Track, in list: [Track]) {
        guard let selected = index.byID[track.id] else { return }
        if load(selected) {
            queue.replace(list.map(\.id).filter { index.byID[$0] != nil }, current: selected.id, shuffled: shuffle)
        }
    }

    @discardableResult private func load(_ track: Track) -> Bool {
        do {
            try engine.prepare(root.appendingPathComponent(track.file))
            currentID = track.id
            elapsed = 0
            duration = track.duration
            engine.start()
            updateSystem()
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func resume() {
        guard currentID != nil else { return }
        do { try engine.resume() } catch { message = error.localizedDescription }
    }

    func toggle() {
        if engine.wantsPlayback { engine.pause() } else { resume() }
    }

    func seek(_ seconds: Double) {
        guard duration > 0, seconds.isFinite else { return }
        let target = min(duration, max(0, seconds))
        engine.seek(target)
        elapsed = target
        updateSystem()
    }

    func advance(_ direction: Int, automatic: Bool = false) {
        guard let currentID else { return }
        if direction < 0, elapsed > 3 { seek(0); return }
        if let id = queue.adjacent(to: currentID, direction: direction), let track = index.byID[id] {
            if !load(track) && automatic { engine.pause() }
        } else if automatic { engine.pause(); seek(0) }
    }

    func favorite(_ track: Track) {
        guard libraryReady, !mutationBusy, let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        mutationBusy = true
        var next = tracks
        next[i].favorite.toggle()
        Task {
            defer { mutationBusy = false }
            do { try await commit(next) }
            catch { message = "Favorite was not saved: \(error.localizedDescription)" }
        }
    }

    func remove(_ track: Track) {
        guard libraryReady, !mutationBusy, let stored = index.byID[track.id] else { return }
        mutationBusy = true
        let next = tracks.filter { $0.id != stored.id }
        Task {
            defer { mutationBusy = false }
            do { try await commit(next) }
            catch { message = "Track was not removed: \(error.localizedDescription)"; return }
            if currentID == stored.id {
                currentID = nil
                engine.clear()
                playing = false
                actualPlaying = false
                elapsed = 0
                duration = 0
                system?.clear()
            }
            queue.remove(stored.id)
            do { try await repository.removeMedia(stored) }
            catch { message = "Track removed from index; media cleanup failed: \(error.localizedDescription)" }
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        if let currentID { queue.setShuffle(shuffle, current: currentID) }
    }

    private func updateSystem() {
        guard let current else { return }
        system?.update(track: current, elapsed: elapsed, duration: duration,
                       playing: actualPlaying, artworkURL: artworkURL(current))
    }
}
