import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

@MainActor final class MusicStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var libraryReady = false
    @Published private(set) var libraryLoading = true
    @Published private(set) var mutationBusy = false
    private(set) var index = LibraryIndex([])
    private let repository: LibraryRepository
    private let importer = AudioImporter()
    @Published var currentID: UUID?
    @Published var playing = false
    let clock = PlaybackClock()
    var elapsed: Double { get { clock.elapsed } set { if clock.elapsed != newValue { clock.elapsed = newValue } } }
    var duration: Double { get { clock.duration } set { if clock.duration != newValue { clock.duration = newValue } } }
    @Published var importing = false
    @Published var message: String?
    @Published var shuffle = false
    @Published var repeatOne = false
    private let player = AVPlayer()
    private var queue = PlaybackQueue()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var wantsPlayback = false
    private var resumeAfterInterruption = false
    private var systemArtworkID: UUID?
    private var artworkTask: Task<Void, Never>?
    private let root: URL
    var current: Track? { currentID.flatMap { index.byID[$0] } }
    init() {
        root = URL.applicationSupportDirectory.appendingPathComponent("AuralLibrary", isDirectory: true)
        repository = LibraryRepository(root: root)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? max(0,time.seconds) : 0
                if let value = self.player.currentItem?.duration.seconds, value.isFinite, value > 0 { self.duration = value }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                if self.repeatOne { self.seek(0); self.player.play() } else { self.advance(1, automatic: true) }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.pause(); self.message = "Playback failed. Try another track."
            }
        }
        stateObserver = player.observe(\.timeControlStatus, options: [.initial,.new]) { [weak self] _,_ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.player.timeControlStatus == .playing
                self.updateSystem()
            }
        }
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(type: type, options: options) }
        })
        sessionObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        let remote = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
            let token = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            remoteTargets.append((command, token))
            command.isEnabled = false
        }
        register(remote.playCommand) { [weak self] in self?.resume() }
        register(remote.pauseCommand) { [weak self] in self?.pause() }
        register(remote.nextTrackCommand) { [weak self] in self?.advance(1) }
        register(remote.previousTrackCommand) { [weak self] in self?.advance(-1) }
        let token = remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.seek(seconds) }
            return .success
        }
        remoteTargets.append((remote.changePlaybackPositionCommand, token))
        remote.changePlaybackPositionCommand.isEnabled = false
        Task { [weak self] in await self?.openLibrary() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for token in [endObserver, failureObserver].compactMap({ $0 }) + sessionObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for (command, token) in remoteTargets { command.removeTarget(token) }
        stateObserver?.invalidate()
        itemObserver?.invalidate()
        artworkTask?.cancel()
    }

    private func openLibrary() async {
        defer { libraryLoading = false }
        do {
            apply(try await repository.load())
            libraryReady = true
        } catch {
            message = "Library could not be opened. Existing files are protected.\n\(error.localizedDescription)"
        }
    }

    private func apply(_ next: [Track]) {
        index = LibraryIndex(next)
        tracks = next
    }

    private func commit(_ next: [Track]) async throws {
        try await repository.commit(next)
        apply(next)
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

    private func handleInterruption(type: UInt?, options: UInt) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            resumeAfterInterruption = wantsPlayback
            wantsPlayback = false
            player.pause()
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let resumePlayback = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            resumeAfterInterruption = false
            if resumePlayback { resume() }
        }
    }

    private func pause() {
        wantsPlayback = false
        resumeAfterInterruption = false
        player.pause()
    }

    func play(_ track: Track, in list: [Track]) {
        guard let selected = index.byID[track.id] else { return }
        if load(selected) { queue.replace(list.map(\.id).filter { index.byID[$0] != nil }, current: selected.id, shuffled: shuffle) }
    }
    @discardableResult private func load(_ track: Track) -> Bool {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default); try AVAudioSession.sharedInstance().setActive(true) }
        catch { message = error.localizedDescription; return false }
        pause(); currentID = track.id; elapsed = 0; duration = track.duration
        let item = AVPlayerItem(url: root.appendingPathComponent(track.file)); player.replaceCurrentItem(with: item)
        itemObserver = item.observe(\.status, options: [.initial,.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed { self.player.pause(); self.message = item.error?.localizedDescription ?? "Unable to play this file." }
            }
        }
        wantsPlayback = true
        player.play(); updateSystem()
        return true
    }
    func resume() { guard currentID != nil else { return }; do { try AVAudioSession.sharedInstance().setActive(true); wantsPlayback = true; player.play() } catch { message = error.localizedDescription } }
    func toggle() { if wantsPlayback { pause() } else { resume() } }
    func seek(_ seconds: Double) { guard duration > 0, seconds.isFinite else { return }; let time = min(duration,max(0,seconds)); player.seek(to: CMTime(seconds: time, preferredTimescale: 600)); elapsed = time; updateSystem() }
    func advance(_ direction: Int, automatic: Bool = false) {
        guard let currentID else { return }
        if direction < 0, elapsed > 3 { seek(0); return }
        if let id = queue.adjacent(to: currentID, direction: direction), let track = index.byID[id] { load(track) }
        else if automatic { pause(); seek(0) }
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
                pause()
                player.replaceCurrentItem(with: nil)
                itemObserver?.invalidate()
                currentID = nil
                playing = false
                elapsed = 0
                duration = 0
                artworkTask?.cancel()
                systemArtworkID = nil
                for (command, _) in remoteTargets { command.isEnabled = false }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        let center = MPNowPlayingInfoCenter.default()
        if systemArtworkID == current.id {
            info[MPMediaItemPropertyArtwork] = center.nowPlayingInfo?[MPMediaItemPropertyArtwork]
        } else {
            systemArtworkID = current.id
            artworkTask?.cancel()
            if let url = artworkURL(current) {
                artworkTask = Task { [weak self] in
                    let image = await ArtworkCache.shared.image(at: url, maxPixelSize: 512)
                    guard !Task.isCancelled, let self, self.currentID == current.id, let image else { return }
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
        }
        for (command, _) in remoteTargets { command.isEnabled = true }
        center.nowPlayingInfo = info
    }
}
