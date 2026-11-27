import Foundation
import MediaPlayer
import UIKit

/// Owns system metadata and command registration, not playback or library state.
@MainActor final class NowPlayingController {
    private let gate = RemoteCommandGate()
    private var targets: [(MPRemoteCommand, Any, RemoteCommandGate.Command)] = []
    private var artworkTask: Task<Void, Never>?
    private var trackID: UUID?
    private var artwork: MPMediaItemArtwork?
    private var info: [String: Any] = [:]

    init(play: @escaping @MainActor @Sendable () -> Void, pause: @escaping @MainActor @Sendable () -> Void,
         next: @escaping @MainActor @Sendable () -> Void, previous: @escaping @MainActor @Sendable () -> Void,
         seek: @escaping @MainActor @Sendable (Double) -> Void) {
        let remote = MPRemoteCommandCenter.shared()
        let gate = self.gate
        func register(_ command: MPRemoteCommand, _ kind: RemoteCommandGate.Command,
                      _ action: @escaping @MainActor @Sendable () -> Void) {
            let token = command.addTarget { @Sendable _ in
                guard let id = gate.accept(kind) else { return .commandFailed }
                Task { @MainActor in
                    guard gate.isCurrent(id, command: kind) else { return }
                    action()
                }
                return .success
            }
            targets.append((command, token, kind))
            command.isEnabled = false
        }
        register(remote.playCommand, .play, play)
        register(remote.pauseCommand, .pause, pause)
        register(remote.nextTrackCommand, .next, next)
        register(remote.previousTrackCommand, .previous, previous)
        let token = remote.changePlaybackPositionCommand.addTarget { @Sendable event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite, event.positionTime >= 0,
                  let id = gate.accept(.seek) else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in
                guard gate.isCurrent(id, command: .seek) else { return }
                seek(seconds)
            }
            return .success
        }
        targets.append((remote.changePlaybackPositionCommand, token, .seek))
        remote.changePlaybackPositionCommand.isEnabled = false
    }

    isolated deinit {
        artworkTask?.cancel()
        gate.update(trackID: nil, available: [])
        for (command, token, _) in targets {
            command.isEnabled = false
            command.removeTarget(token)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func update(track: Track, revision: Int, elapsed: Double, duration: Double, playing: Bool,
                available: Set<RemoteCommandGate.Command>, artworkURL: URL?) {
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
        gate.update(trackID: track.id, revision: revision, available: available)
        for (command, _, kind) in targets { command.isEnabled = available.contains(kind) }
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
        gate.update(trackID: nil, available: [])
        for (command, _, _) in targets { command.isEnabled = false }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
