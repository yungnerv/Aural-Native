import Foundation
import Combine

/// Main-actor coordinator. The repository owns persistence, the importer owns file
/// inspection, and the playback engine and system bridge own platform integration.
@MainActor final class MusicStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var libraryReady = false
    @Published private(set) var libraryLoading = true
    @Published private(set) var recoveryReport: LibraryRepository.RecoveryReport?
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
            let crossedRestartThreshold = (self.elapsed > 3) != (elapsed > 3)
            self.elapsed = elapsed
            var changed = crossedRestartThreshold
            if let duration, self.duration != duration {
                self.duration = duration
                changed = true
            }
            if changed { self.updateSystem() }
        }
        engine.onState = { [weak self] wanted, audible in
            guard let self else { return }
            let changed = self.playing != wanted || self.actualPlaying != audible
            if self.playing != wanted { self.playing = wanted }
            if self.actualPlaying != audible { self.actualPlaying = audible }
            if changed { self.updateSystem() }
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
        libraryLoading = true
        recoveryReport = nil
        defer { libraryLoading = false }
        do {
            await apply(try await repository.load())
            libraryReady = true
        } catch {
            libraryReady = false
            recoveryReport = try? await repository.inspectRecovery()
            message = "Library could not be opened. Existing files are protected.\n\(error.localizedDescription)"
        }
    }

    func retryLibrary() {
        guard !mutationBusy, !libraryLoading else { return }
        mutationBusy = true
        libraryReady = false
        Task {
            defer { mutationBusy = false }
            await openLibrary()
        }
    }

    func restoreLibrary() {
        guard !libraryReady, !mutationBusy, !libraryLoading,
              recoveryReport?.canRestore == true else { return }
        mutationBusy = true
        libraryLoading = true
        Task {
            defer { mutationBusy = false; libraryLoading = false }
            do {
                let restored = try await repository.restorePreviousIndex()
                await apply(restored)
                recoveryReport = nil
                libraryReady = true
                message = "Previous library index restored. Original files were preserved."
            } catch {
                recoveryReport = try? await repository.inspectRecovery()
                message = "Recovery was not completed: \(error.localizedDescription)"
            }
        }
    }

    private func reportMutationError(_ error: Error) {
        if let failure = error as? LibraryRepository.Failure, failure.requiresReopen {
            libraryReady = false
            recoveryReport = nil
        }
    }

    private func apply(_ next: [Track]) async {
        index = await repository.makeIndex(next)
        tracks = next
        queue.retain(Set(index.byID.keys))
        if let currentID, index.byID[currentID] == nil {
            self.currentID = nil
            engine.clear()
            playing = false
            actualPlaying = false
            elapsed = 0
            duration = 0
            system?.clear()
            queue.remove(currentID)
        }
        updateSystem()
    }

    private func commit(_ next: [Track]) async throws {
        do { try await repository.commit(next) }
        catch { reportMutationError(error); throw error }
        await apply(next)
    }

    func artworkURL(_ track: Track) -> URL? {
        track.artwork.map { root.appendingPathComponent($0) }
    }

    func importFiles(_ urls: [URL]) async {
        guard libraryReady, !mutationBusy else {
            message = libraryReady ? "Wait for the current library operation to finish." : "Reopen the library before importing."
            return
        }
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
                catch { reportMutationError(error); errors.append("Could not clean up \(track.title): \(error.localizedDescription)") }
            }
            errors.append(error.localizedDescription)
        }
        if duplicates > 0 { errors.append("\(duplicates) duplicate file(s) skipped.") }
        if !errors.isEmpty { message = errors.joined(separator: "\n") }
    }

    func play(_ track: Track, in list: [Track]) {
        guard libraryReady, let selected = index.byID[track.id] else { return }
        if load(selected) {
            queue.replace(list.map(\.id).filter { index.byID[$0] != nil }, current: selected.id, shuffled: shuffle)
            updateSystem()
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
        guard libraryReady, !mutationBusy else { message = "The library is busy or unavailable."; return }
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
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
        guard libraryReady, !mutationBusy else { message = "The library is busy or unavailable."; return }
        guard let stored = index.byID[track.id] else { return }
        mutationBusy = true
        let next = tracks.filter { $0.id != stored.id }
        Task {
            defer { mutationBusy = false }
            do { try await commit(next) }
            catch { message = "Track was not removed: \(error.localizedDescription)"; return }
            queue.remove(stored.id)
            do { try await repository.removeMedia(stored) }
            catch { reportMutationError(error); message = "Track removed from index; media cleanup failed: \(error.localizedDescription)" }
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        if let currentID { queue.setShuffle(shuffle, current: currentID) }
        updateSystem()
    }

    private func updateSystem() {
        guard let current else { return }
        var available: Set<RemoteCommandGate.Command> = [playing ? .pause : .play]
        if queue.adjacent(to: current.id, direction: 1) != nil { available.insert(.next) }
        if elapsed > 3 || queue.adjacent(to: current.id, direction: -1) != nil { available.insert(.previous) }
        if duration > 0 { available.insert(.seek) }
        system?.update(track: current, elapsed: elapsed, duration: duration,
                       playing: actualPlaying, available: available, artworkURL: artworkURL(current))
    }
}
