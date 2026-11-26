import Foundation
import AVFoundation

/// AVPlayer lifecycle, audio session and observation. No library or view dependencies.
@MainActor final class PlaybackEngine {
    private var player = AVPlayer()
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var stateObserver: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var seekGeneration = 0
    private var seeking = false
    private var preparedURL: URL?
    private var mediaReset = false
    private(set) var wantsPlayback = false
    var isPlaying: Bool { player.timeControlStatus == .playing }

    var onProgress: ((Double, Double?) -> Void)?
    var onState: ((Bool, Bool) -> Void)?
    var onEnd: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onSeek: (() -> Void)?

    init() {
        installPlayerObservers()
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.onEnd?()
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.fail("Playback failed. Try another track.")
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleMediaReset() }
        })
    }

    private func installPlayerObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reportProgress() }
        }
        stateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.reportState() }
        }
    }

    private func handleMediaReset() {
        // Recreate media-server objects after reset. Never restart audio without
        // user intent. Resume will prepare the same URL on the new player.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        stateObserver?.invalidate()
        stateObserver = nil
        itemObserver?.invalidate()
        itemObserver = nil
        seekGeneration += 1
        seeking = false
        wantsPlayback = false
        resumeAfterInterruption = false
        player = AVPlayer()
        mediaReset = preparedURL != nil
        installPlayerObservers()
        reportState()
        if mediaReset {
            onFailure?("Audio services restarted. Press Play to resume the selected track from the beginning.")
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        stateObserver?.invalidate()
        itemObserver?.invalidate()
    }

    private func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    /// Do not switch the existing item until session activation succeeds.
    func prepare(_ url: URL) throws {
        try activate()
        preparedURL = url
        mediaReset = false
        player.pause()
        wantsPlayback = false
        resumeAfterInterruption = false
        seekGeneration += 1
        seeking = false
        itemObserver?.invalidate()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.fail(item.error?.localizedDescription ?? "Unable to play this file.")
                }
            }
        }
    }

    func start() {
        guard player.currentItem != nil else { return }
        wantsPlayback = true
        resumeAfterInterruption = false
        player.play()
        reportState()
    }

    func resume() throws {
        if mediaReset, let url = preparedURL {
            try prepare(url)
            onProgress?(0, nil)
        } else {
            guard player.currentItem != nil else { return }
            try activate()
        }
        start()
    }

    func pause() {
        wantsPlayback = false
        resumeAfterInterruption = false
        player.pause()
        reportState()
    }

    func clear() {
        preparedURL = nil
        mediaReset = false
        pause()
        seekGeneration += 1
        seeking = false
        itemObserver?.invalidate()
        itemObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    func seek(_ seconds: Double, resumeAfterSeek: Bool = false) {
        guard let item = player.currentItem, seconds.isFinite else { return }
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation,
                      self.player.currentItem === item else { return }
                self.seeking = false
                if finished && resumeAfterSeek && self.wantsPlayback { self.player.play() }
                self.reportProgress()
                self.onSeek?()
            }
        }
    }

    private func reportProgress() {
        guard !seeking, player.currentItem != nil else { return }
        let seconds = player.currentTime().seconds
        let total = player.currentItem?.duration.seconds
        onProgress?(seconds.isFinite ? max(0, seconds) : 0,
                    total.flatMap { $0.isFinite && $0 > 0 ? $0 : nil })
    }

    private func reportState() { onState?(wantsPlayback, isPlaying) }

    private func fail(_ message: String) {
        pause()
        onFailure?(message)
    }

    private func interruption(type: UInt?, options: UInt) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            resumeAfterInterruption = wantsPlayback
            wantsPlayback = false
            player.pause()
            reportState()
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            let shouldResume = resumeAfterInterruption &&
                AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            resumeAfterInterruption = false
            if shouldResume {
                do { try resume() } catch { fail(error.localizedDescription) }
            }
        }
    }
}
