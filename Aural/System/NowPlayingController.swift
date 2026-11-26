import Foundation
import MediaPlayer
import UIKit

/// Owns system metadata and command registration, not playback or library state.
@MainActor final class NowPlayingController {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var trackID: UUID?
    private var artwork: MPMediaItemArtwork?
    private var info: [String: Any] = [:]

    init(play: @escaping () -> Void, pause: @escaping () -> Void,
         next: @escaping () -> Void, previous: @escaping () -> Void,
         seek: @escaping (Double) -> Void) {
        let remote = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
            let token = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            targets.append((command, token))
            command.isEnabled = false
        }
        register(remote.playCommand, play)
        register(remote.pauseCommand, pause)
        register(remote.nextTrackCommand, next)
        register(remote.previousTrackCommand, previous)
        let token = remote.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in seek(seconds) }
            return .success
        }
        targets.append((remote.changePlaybackPositionCommand, token))
        remote.changePlaybackPositionCommand.isEnabled = false
    }

    deinit {
        artworkTask?.cancel()
        for (command, token) in targets { command.removeTarget(token) }
    }

    func update(track: Track, elapsed: Double, duration: Double, playing: Bool, artworkURL: URL?) {
        if trackID != track.id {
            trackID = track.id
            artworkTask?.cancel()
            artwork = nil
            if let artworkURL {
                artworkTask = Task { [weak self] in
                    let image = await ArtworkCache.shared.image(at: artworkURL, maxPixelSize: 512)
                    guard !Task.isCancelled, let self, self.trackID == track.id, let image else { return }
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.publish()
                }
            }
        }
        info = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        for (command, _) in targets { command.isEnabled = true }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = duration > 0
        publish()
    }

    private func publish() {
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        else { info.removeValue(forKey: MPMediaItemPropertyArtwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        artworkTask?.cancel()
        trackID = nil
        artwork = nil
        info = [:]
        for (command, _) in targets { command.isEnabled = false }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
