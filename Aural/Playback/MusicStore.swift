import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers
import Combine
import UIKit
import ImageIO

@MainActor final class MusicStore: ObservableObject {
    @Published var tracks: [Track] = []
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
    private var queue: [UUID] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private let root: URL
    private let fm = FileManager.default
    var current: Track? { tracks.first { $0.id == currentID } }
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AuralLibrary", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let index = root.appendingPathComponent("library.json")
            if fm.fileExists(atPath: index.path) { tracks = try JSONDecoder().decode([Track].self, from: Data(contentsOf: index)) }
        } catch { message = "Library could not be opened: \(error.localizedDescription)" }
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
                self.player.pause(); self.message = "Playback failed. Try another track."
            }
        }
        stateObserver = player.observe(\.timeControlStatus, options: [.initial,.new]) { [weak self] _,_ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.player.timeControlStatus == .playing
                self.updateSystem()
            }
        }
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.advance(1) }; return .success }
        remote.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.advance(-1) }; return .success }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in self?.seek(seconds) }; return .success
        }
    }
    func save() { do { try JSONEncoder().encode(tracks).write(to: root.appendingPathComponent("library.json"), options: .atomic) } catch { message = "Could not save library: \(error.localizedDescription)" } }
    func artworkURL(_ track: Track) -> URL? { track.artwork.map { root.appendingPathComponent($0) } }
    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }; importing = true; defer { importing = false }
        let base = root
        var errors: [String] = []
        for url in urls {
            do {
                let track = try await Task.detached(priority: .userInitiated) { try await Self.readFile(url, into: base) }.value
                tracks.append(track); save()
            } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !errors.isEmpty { message = errors.joined(separator: "\n") }
    }
    nonisolated private static func readFile(_ url: URL, into root: URL) async throws -> Track {
        let fm = FileManager.default
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let name = id.uuidString + "." + url.pathExtension.lowercased()
        let destination = root.appendingPathComponent(name)
        var artName: String?
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                do { try fm.copyItem(at: readable, to: destination) } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }; if let copyError { throw copyError }
            let asset = AVURLAsset(url: destination)
            let playable = try await asset.load(.isPlayable)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard playable, !audio.isEmpty else { throw NSError(domain: "Aural", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format or damaged file"]) }
            let d = try await asset.load(.duration).seconds
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            func value(_ key: AVMetadataKey) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first else { return nil }
                return try? await item.load(.stringValue)
            }
            let filename = url.deletingPathExtension().lastPathComponent
            let parts = filename.components(separatedBy: " - ")
            let title = await value(.commonKeyTitle) ?? (parts.count == 2 ? parts[1] : filename)
            let artist = await value(.commonKeyArtist) ?? (parts.count == 2 ? parts[0] : "Unknown artist")
            let album = await value(.commonKeyAlbumName) ?? "Unknown album"
            if let item = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
               let data = try? await item.load(.dataValue), data.count <= 20_000_000 {
                // Downsample off the main actor using ImageIO, not a full-size decoded bitmap.
                if let jpeg = thumbnail(data) {
                    let art = id.uuidString + ".jpg"
                    try jpeg.write(to: root.appendingPathComponent(art), options: .atomic); artName = art
                }
            }
            return Track(id: id, file: name, title: title, artist: artist, album: album, duration: d.isFinite ? max(0,d) : 0, artwork: artName)
        } catch { try? fm.removeItem(at: destination); if let artName { try? fm.removeItem(at: root.appendingPathComponent(artName)) }; throw error }
    }
    nonisolated private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }; return output as Data
    }
    func play(_ track: Track, in list: [Track]) {
        queue = list.map(\.id); if shuffle { queue = [track.id] + queue.filter { $0 != track.id }.shuffled() }; load(track)
    }
    private func load(_ track: Track) {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default); try AVAudioSession.sharedInstance().setActive(true) }
        catch { message = error.localizedDescription; return }
        player.pause(); currentID = track.id; elapsed = 0; duration = track.duration
        let item = AVPlayerItem(url: root.appendingPathComponent(track.file)); player.replaceCurrentItem(with: item)
        itemObserver = item.observe(\.status, options: [.initial,.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed { self.player.pause(); self.message = item.error?.localizedDescription ?? "Unable to play this file." }
            }
        }
        player.play(); updateSystem()
    }
    func resume() { guard currentID != nil else { return }; do { try AVAudioSession.sharedInstance().setActive(true); player.play() } catch { message = error.localizedDescription } }
    func toggle() { if player.rate != 0 { player.pause() } else { resume() } }
    func seek(_ seconds: Double) { guard duration > 0, seconds.isFinite else { return }; let time = min(duration,max(0,seconds)); player.seek(to: CMTime(seconds: time, preferredTimescale: 600)); elapsed = time; updateSystem() }
    func advance(_ direction: Int, automatic: Bool = false) {
        guard let currentID, let index = queue.firstIndex(of: currentID) else { return }
        if direction < 0, elapsed > 3 { seek(0); return }
        let next = index + direction
        if !queue.indices.contains(next) { if automatic { player.pause(); seek(0) }; return }
        if let track = tracks.first(where: { $0.id == queue[next] }) { load(track) }
    }
    func favorite(_ track: Track) { if let index = tracks.firstIndex(where: { $0.id == track.id }) { tracks[index].favorite.toggle(); save() } }
    func remove(_ track: Track) {
        if currentID == track.id { player.pause(); player.replaceCurrentItem(with: nil); currentID = nil; elapsed = 0; duration = 0; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        queue.removeAll { $0 == track.id }; tracks.removeAll { $0.id == track.id }; save()
        try? fm.removeItem(at: root.appendingPathComponent(track.file)); if let art = artworkURL(track) { try? fm.removeItem(at: art) }
    }
    func toggleShuffle() {
        shuffle.toggle(); guard let currentID else { return }
        if shuffle { queue = [currentID] + queue.filter { $0 != currentID }.shuffled() }
        else { let ids = Set(queue); queue = tracks.filter { ids.contains($0.id) }.map(\.id) }
    }
    private func updateSystem() {
        guard let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist, MPMediaItemPropertyAlbumTitle: current.album, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        // Reuse already registered artwork when the song does not change.
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == current.title, let art = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] { info[MPMediaItemPropertyArtwork] = art }
        else if let url = artworkURL(current), let image = UIImage(contentsOfFile: url.path) { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        center.nowPlayingInfo = info
    }
}
