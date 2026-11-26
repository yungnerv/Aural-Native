import AVFoundation
import Foundation

/// Owns the player, session and observations on the main actor.
/// Framework callbacks carry only value-type generations across actor boundaries.
@MainActor final class PlaybackEngine {
    private var player: AVPlayer
    private var timeObserver: Any?
    private var itemObserver: NSKeyValueObservation?
    private var stateObserver: NSKeyValueObservation?
    private var sessionNotifications: [NSObjectProtocol] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var playerGeneration = 0
    private var itemGeneration = 0
    private var seekGeneration = 0
    private var resumeAfterInterruption = false
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

    init(player: AVPlayer = AVPlayer()) {
        self.player = player
        installPlayerObservers()
        installSessionObservers()
    }

    // Isolated destruction guarantees that non-Sendable observer tokens are
    // removed on their owning executor, even if the final release happens elsewhere.
    isolated deinit {
        removeItemObservers()
        removePlayerObservers()
        for token in sessionNotifications {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default
        sessionNotifications.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { @Sendable [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        sessionNotifications.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { @Sendable [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
            }
        })
        sessionNotifications.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in self?.handleMediaReset() }
        })
    }

    private func installPlayerObservers() {
        let generation = playerGeneration
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.playerGeneration == generation else { return }
                self.reportProgress()
            }
        }
        stateObserver = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.playerGeneration == generation else { return }
                self.reportState()
            }
        }
    }

    private func removePlayerObservers() {
        playerGeneration += 1
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        stateObserver?.invalidate()
        stateObserver = nil
    }

    private func installItemObservers(_ item: AVPlayerItem) {
        let generation = itemGeneration
        let center = NotificationCenter.default
        // Filter at registration, not after moving a Notification to another actor.
        itemNotifications.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemGeneration == generation, self.wantsPlayback else { return }
                self.onEnd?()
            }
        })
        itemNotifications.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.itemGeneration == generation else { return }
                self.fail("Playback failed. Try another track.")
            }
        })
        itemObserver = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.itemGeneration == generation,
                      let current = self.player.currentItem, current.status == .failed else { return }
                self.fail(current.error?.localizedDescription ?? "Unable to play this file.")
            }
        }
    }

    private func removeItemObservers() {
        itemGeneration += 1
        seekGeneration += 1
        seeking = false
        itemObserver?.invalidate()
        itemObserver = nil
        for token in itemNotifications {
            NotificationCenter.default.removeObserver(token)
        }
        itemNotifications.removeAll()
    }

    private func handleMediaReset() {
        // Recreate media-server objects. Resume only in response to user intent.
        removeItemObservers()
        removePlayerObservers()
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
        removeItemObservers()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        installItemObservers(item)
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
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
    }

    func seek(_ seconds: Double, resumeAfterSeek: Bool = false) {
        guard player.currentItem != nil, seconds.isFinite else { return }
        seekGeneration += 1
        let generation = seekGeneration
        let item = itemGeneration
        seeking = true
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600)) { @Sendable [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation,
                      self.itemGeneration == item else { return }
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

    private func reportState() {
        onState?(wantsPlayback, isPlaying)
    }

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
