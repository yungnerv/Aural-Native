import Foundation
import Combine
import OSLog

/// Main-actor coordinator. The repository owns persistence, the importer owns file
/// inspection, and the playback engine and system bridge own platform integration.
@MainActor final class MusicStore: ObservableObject {
    @Published private(set) var index = LibraryIndex([])
    var tracks: [Track] { index.tracks }
    @Published private(set) var libraryReady = false
    @Published private(set) var libraryLoading = true
    @Published private(set) var recoveryReport: LibraryRepository.RecoveryReport?
    @Published private(set) var mutationBusy = false
    @Published private(set) var currentID: UUID?
    @Published private(set) var playbackRevision = 0
    @Published private(set) var playing = false
    @Published private(set) var importing = false
    @Published private(set) var importProgress = 0.0
    @Published private(set) var lastImportReport: [String] = []
    @Published var message: String?
    @Published private(set) var shuffle = false
    @Published var repeatOne = false

    let clock = PlaybackClock()
    private let playbackLog = Logger(subsystem: "local.aural.player", category: "Playback")
    private let repository: LibraryRepository
    private let importer = AudioImporter()
    private var importTask: Task<Void, Never>?
    private lazy var engine: PlaybackEngine = makePlaybackEngine()
    private var system: NowPlayingController?
    private let root: URL
    private var queue = PlaybackQueue()
    private var actualPlaying = false
    var current: Track? { currentID.flatMap { index[$0] } }
    @Published private(set) var canAdvance = false
    @Published private(set) var canGoBack = false
    var canSeek: Bool { libraryReady && currentID != nil && duration > 0 && engine.canSeek }
    var canToggle: Bool { currentID != nil && (playing || libraryReady) }

    private var elapsed: Double {
        get { clock.elapsed }
        set { if clock.elapsed != newValue { clock.elapsed = newValue } }
    }
    private var duration: Double {
        get { clock.duration }
        set { if clock.duration != newValue { clock.duration = newValue } }
    }

    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("AuralLibrary", isDirectory: true)) {
        self.root = root
        repository = LibraryRepository(root: root)
        Task { [weak self] in await self?.openLibrary() }
    }

    private func makePlaybackEngine() -> PlaybackEngine {
        let engine = PlaybackEngine()
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
            let changed = self.playing != wanted || self.actualPlaying != audible ||
                self.playbackRevision != self.engine.itemGeneration
            if self.playbackRevision != self.engine.itemGeneration {
                self.playbackRevision = self.engine.itemGeneration
            }
            if self.playing != wanted { self.playing = wanted }
            if self.actualPlaying != audible { self.actualPlaying = audible }
            if changed { self.updateSystem() }
        }
        engine.onEnd = { [weak self] in
            guard let self else { return }
            guard self.libraryReady else { self.engine.pause(); return }
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
        return engine
    }

    private func openLibrary() async {
        libraryLoading = true
        recoveryReport = nil
        defer { libraryLoading = false }
        do {
            await apply(try await repository.load())
            libraryReady = true
            updateSystem()
        } catch {
            libraryReady = false
            updateSystem()
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
                updateSystem()
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
            updateSystem()
        }
    }

    private func apply(_ next: [Track]) async {
        index = await repository.makeIndex(next)
        let positions = index.positionByID
        queue.retain { positions[$0] != nil }
        if let currentID, index[currentID] == nil {
            self.currentID = nil
            engine.clear()
            playing = false
            actualPlaying = false
            elapsed = 0
            duration = 0
            system?.clear()
        }
        updateSystem()
    }

    @discardableResult
    private func commit(_ next: [Track]) async throws -> [String] {
        let diagnostics: [String]
        do { diagnostics = try await repository.commit(next) }
        catch { reportMutationError(error); throw error }
        await apply(next)
        return diagnostics
    }

    func artworkURL(_ track: Track) -> URL? {
        track.artwork.map { root.appendingPathComponent($0) }
    }

    func beginImport(_ urls: [URL]) {
        guard importTask == nil, !urls.isEmpty else { return }
        importTask = Task { [weak self] in
            guard let self else { return }
            await self.importFiles(urls)
            self.importTask = nil
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func importFiles(_ urls: [URL]) async {
        guard libraryReady, !mutationBusy else {
            message = libraryReady ? "Wait for the current library operation to finish." : "Reopen the library before importing."
            return
        }
        importing = true
        importProgress = 0
        lastImportReport = []
        mutationBusy = true
        defer {
            importing = false
            mutationBusy = false
            importProgress = 0
        }
        var next = tracks
        var pending: [Track] = []
        var hashes = Set(next.compactMap { $0.contentHash?.lowercased() })
        var errors: [String] = []
        var hashesUpdated = false
        var duplicates = 0
        var processed = 0
        var lastUpdate = ContinuousClock.now
        do {
            for i in next.indices where next[i].contentHash == nil {
                try Task.checkCancellation()
                do {
                    let digest = try await importer.digest(root.appendingPathComponent(next[i].file))
                    next[i].contentHash = digest
                    hashes.insert(digest)
                    hashesUpdated = true
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
                processed += 1
                if ContinuousClock.now - lastUpdate >= .milliseconds(100) || processed == urls.count {
                    importProgress = Double(processed) / Double(urls.count)
                    lastUpdate = ContinuousClock.now
                }
                // Bound uncommitted imports while reducing whole-index writes.
                let batchSize = min(128, max(16, next.count / 64))
                if pending.count >= batchSize {
                    try Task.checkCancellation()
                    errors += try await commit(next)
                    hashesUpdated = false
                    pending.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if hashesUpdated || !pending.isEmpty { errors += try await commit(next) }
            pending.removeAll()
        } catch {
            if !pending.isEmpty {
                // Cleanup must finish even when the importing task was cancelled.
                let cleanup = Task { [repository, pending] in
                    try await repository.discardImports(pending)
                }
                do { errors += try await cleanup.value }
                catch { reportMutationError(error); errors.append(error.localizedDescription) }
            }
            if error is CancellationError {
                errors.append("Import cancelled. Successfully committed tracks were kept.")
            } else {
                errors.append(error.localizedDescription)
            }
        }
        if duplicates > 0 { errors.append("\(duplicates) duplicate file(s) skipped.") }
        if !errors.isEmpty {
            lastImportReport = errors
            let preview = errors.prefix(4).joined(separator: "\n")
            message = errors.count > 4
                ? "\(preview)\n\(errors.count - 4) more entries in Settings → Last import report."
                : preview
        }
    }

    func play(_ track: Track, in list: [Track]) {
        playbackLog.debug("Track selection requested")
        guard libraryReady else {
            playbackLog.error("Selection rejected: library unavailable")
            message = "Reopen the library before playing music."
            return
        }
        guard let selected = index[track.id] else {
            playbackLog.error("Selection rejected: track no longer indexed")
            message = "This track is no longer in the library."
            return
        }
        load(selected, replacementQueue: list.map(\.id).filter { index[$0] != nil })
    }

    @discardableResult private func load(_ track: Track, replacementQueue: [UUID]? = nil) -> Bool {
        do {
            try engine.prepare(root.appendingPathComponent(track.file))
            if let replacementQueue {
                queue.replace(replacementQueue, current: track.id, shuffled: shuffle)
            }
            currentID = track.id
            playbackRevision = engine.itemGeneration
            elapsed = 0
            duration = track.duration
            engine.start()
            updateSystem()
            playbackLog.debug("Track selected and playback requested")
            return true
        } catch {
            let failure = error as NSError
            playbackLog.error("Playback preparation failed: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
            message = error.localizedDescription
            return false
        }
    }

    func resume() {
        guard libraryReady, currentID != nil else { return }
        do { try engine.resume() } catch { message = error.localizedDescription }
    }

    func toggle() {
        if engine.wantsPlayback { engine.pause() } else { resume() }
    }

    func seek(_ seconds: Double) {
        guard libraryReady, duration > 0, seconds.isFinite else { return }
        let target = min(duration, max(0, seconds))
        guard engine.seek(target) else {
            message = "Playback position is unavailable. Press Play to prepare the selected track."
            return
        }
        elapsed = target
        updateSystem()
    }

    func advance(_ direction: Int, automatic: Bool = false) {
        guard libraryReady, let currentID else {
            if automatic { engine.pause() }
            return
        }
        if direction < 0, elapsed > 3 { seek(0); return }
        if let id = queue.adjacent(to: currentID, direction: direction), let track = index[id] {
            if !load(track) && automatic { engine.pause() }
        } else if automatic { engine.pause(); seek(0) }
    }

    func favorite(_ track: Track) {
        guard libraryReady, !mutationBusy else { message = "The library is busy or unavailable."; return }
        guard let i = index.positionByID[track.id] else { return }
        mutationBusy = true
        var next = tracks
        next[i].favorite.toggle()
        Task {
            defer { mutationBusy = false }
            do {
                let diagnostics = try await commit(next)
                if !diagnostics.isEmpty { message = diagnostics.joined(separator: "\n") }
            } catch {
                message = "Favorite was not saved: \(error.localizedDescription)"
            }
        }
    }

    func remove(_ track: Track) {
        guard libraryReady, !mutationBusy else { message = "The library is busy or unavailable."; return }
        guard let stored = index[track.id] else { return }
        mutationBusy = true
        let next = tracks.filter { $0.id != stored.id }
        Task {
            defer { mutationBusy = false }
            let diagnostics: [String]
            do { diagnostics = try await commit(next) }
            catch { message = "Track was not removed: \(error.localizedDescription)"; return }
            if !diagnostics.isEmpty { message = diagnostics.joined(separator: "\n") }
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        if let currentID { queue.setShuffle(shuffle, current: currentID) }
        updateSystem()
    }

    private func updateSystem() {
        let nextAvailable = libraryReady && currentID.flatMap { queue.adjacent(to: $0, direction: 1) } != nil
        let previousAvailable = libraryReady && currentID != nil &&
            (elapsed > 3 || currentID.flatMap { queue.adjacent(to: $0, direction: -1) } != nil)
        if canAdvance != nextAvailable { canAdvance = nextAvailable }
        if canGoBack != previousAvailable { canGoBack = previousAvailable }
        guard let current else { return }
        var available: Set<RemoteCommandGate.Command> = []
        if playing { available.insert(.pause) }
        else if libraryReady { available.insert(.play) }
        if canAdvance { available.insert(.next) }
        if canGoBack { available.insert(.previous) }
        if canSeek { available.insert(.seek) }
        system?.update(track: current, revision: playbackRevision, elapsed: elapsed, duration: duration,
                       playing: actualPlaying, available: available, artworkURL: artworkURL(current))
    }
}
