import AVFoundation
import Foundation
import XCTest
@testable import Aural

final class NativeIntegrationTests: XCTestCase {
    private func fixture(at url: URL) throws {
        // One second of silent PCM, generated locally: no copyrighted audio or
        // external fixture download is needed for the integration tests.
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames: AVAudioFrameCount = 44_100
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { channel[i] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testImportPreservesBytesAndRejectsDuplicate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Artist - Test.wav")
        try fixture(at: source)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let importer = AudioImporter()
        let imported = try await importer.readFile(source, into: library, knownHashes: [])
        let track = try XCTUnwrap(imported)
        XCTAssertEqual(track.title, "Test")
        XCTAssertEqual(track.artist, "Artist")
        XCTAssertEqual(track.duration, 1, accuracy: 0.05)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: library.appendingPathComponent(track.file)))
        let digest = try XCTUnwrap(track.contentHash)
        let duplicate = try await importer.readFile(source, into: library, knownHashes: [digest])
        XCTAssertNil(duplicate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).count, 1)
    }

    @MainActor
    func testTaggedM4AImportPreservesEmbeddedMetadataAndBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wav = root.appendingPathComponent("fixture.wav")
        try fixture(at: wav)
        let source = root.appendingPathComponent("Tagged fixture.m4a")
        let session = try XCTUnwrap(AVAssetExportSession(
            asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A))
        func tag(_ identifier: AVMetadataIdentifier, _ text: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = text as NSString
            return item
        }
        session.metadata = [
            tag(.iTunesMetadataAlbumArtist, "Fixture Album Artist"),
            tag(.iTunesMetadataComposer, "Fixture Composer"),
            tag(.iTunesMetadataUserGenre, "Fixture Genre"),
        ]
        // Transcoding is solely for generating this synthetic test fixture.
        // The importer must preserve the resulting file byte for byte.
        try await session.export(to: source, as: .m4a)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let imported = try await AudioImporter().readFile(source, into: library, knownHashes: [])
        let track = try XCTUnwrap(imported)
        let metadata = try XCTUnwrap(track.metadata)
        XCTAssertEqual(metadata.albumArtist, "Fixture Album Artist")
        XCTAssertEqual(metadata.composer, "Fixture Composer")
        XCTAssertEqual(metadata.genre, "Fixture Genre")
        XCTAssertEqual(metadata.originalFilename, "Tagged fixture.m4a")
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: library.appendingPathComponent(track.file)))
    }

    func testInvalidAudioLeavesNoImportedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: source)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        do {
            _ = try await AudioImporter().readFile(source, into: library, knownHashes: [])
            XCTFail("Invalid audio was accepted")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDirectoryAndSymlinkAreRejectedBeforePublishing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent("folder.wav", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try fixture(at: source)
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for invalid in [folder, link] {
            do {
                _ = try await AudioImporter().readFile(invalid, into: library, knownHashes: [])
                XCTFail("Nonregular source accepted: \(invalid.lastPathComponent)")
            } catch {}
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testBatchImportPreservesDistinctAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let importer = AudioImporter()
        var hashes = Set<String>()
        let started = ContinuousClock.now
        for index in 0..<16 {
            let source = root.appendingPathComponent("Track-\(index).wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
            buffer.frameLength = 4_410
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<4_410 {
                samples[frame] = Float(sin(Double(frame) * Double(index + 1) * 0.01) * 0.1)
            }
            do {
                let file = try AVAudioFile(forWriting: source, settings: format.settings)
                try file.write(from: buffer)
            }
            let imported = try await importer.readFile(source, into: library, knownHashes: hashes)
            let track = try XCTUnwrap(imported)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: library.appendingPathComponent(track.file)))
            let hash = try XCTUnwrap(track.contentHash)
            XCTAssertTrue(hashes.insert(hash).inserted)
        }
        XCTAssertEqual(hashes.count, 16)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path).count, 16)
        print("16 distinct PCM imports on simulator: \(ContinuousClock.now - started)")
    }

    @MainActor
    func testPlaybackIntentAndLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.wav")
        try fixture(at: url)
        let engine = PlaybackEngine()
        try engine.prepare(url)
        XCTAssertFalse(engine.wantsPlayback)
        engine.start()
        XCTAssertTrue(engine.wantsPlayback)
        engine.pause()
        XCTAssertFalse(engine.wantsPlayback)
        try engine.resume()
        XCTAssertTrue(engine.wantsPlayback)
        engine.clear()
        XCTAssertFalse(engine.wantsPlayback)
        XCTAssertFalse(engine.seek(0.5), "No prepared item must reject a seek")
        try engine.resume()
        XCTAssertFalse(engine.wantsPlayback)
    }

    @MainActor
    func testReplacedItemCannotDeliverStaleEndOrFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.wav")
        try fixture(at: url)
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        var ends = 0
        var failures = 0
        engine.onEnd = { ends += 1 }
        engine.onFailure = { _ in failures += 1 }

        try engine.prepare(url)
        let oldItem = try XCTUnwrap(player.currentItem)
        engine.start()
        // Enqueue events before replacement; those already dispatched must also
        // fail the generation check, not just notifications from removed observers.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
        try engine.prepare(url)
        let currentItem = try XCTUnwrap(player.currentItem)
        engine.start()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: currentItem)
        // Allow callbacks on the main actor, with a bounded timeout.
        let deadline = ContinuousClock.now + .seconds(2)
        while ends == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        engine.clear()
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(failures, 0)
    }

    @MainActor
    func testFailedToEndDetachesItemAndExplicitRetryRebuildsIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(at: url)
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        defer { engine.clear() }
        try engine.prepare(url)
        let oldItem = try XCTUnwrap(player.currentItem)
        var failures = 0
        engine.onFailure = { _ in failures += 1 }
        for _ in 0..<2 {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while player.currentItem != nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(engine.canSeek)
        XCTAssertFalse(engine.wantsPlayback)
        try engine.resume()
        let replacement = try XCTUnwrap(player.currentItem)
        XCTAssertFalse(replacement === oldItem)
        XCTAssertTrue(engine.wantsPlayback)
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testDuplicateInterruptionPreservesIntentUntilExplicitPause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("interruption.wav")
        try fixture(at: url)
        let engine = PlaybackEngine()
        defer { engine.clear() }
        try engine.prepare(url)
        engine.start()

        func post(_ type: AVAudioSession.InterruptionType) {
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                           AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        }
        post(.began)
        XCTAssertFalse(engine.wantsPlayback)
        post(.began)
        post(.ended)
        XCTAssertTrue(engine.wantsPlayback)

        post(.began)
        engine.pause()
        post(.ended)
        XCTAssertFalse(engine.wantsPlayback)
    }

    @MainActor
    func testMediaResetRequiresExplicitResumeAndRestoresPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.wav")
        try fixture(at: url)
        let engine = PlaybackEngine()
        defer { engine.clear() }
        var position = 0.0
        var completedSeeks = 0
        var resetReported = false
        engine.onProgress = { elapsed, _ in position = elapsed }
        engine.onSeek = { completedSeeks += 1 }
        engine.onFailure = { message in
            if message.contains("Audio services restarted") { resetReported = true }
        }
        try engine.prepare(url)
        XCTAssertTrue(engine.seek(0.5))
        let seekDeadline = ContinuousClock.now + .seconds(5)
        while completedSeeks == 0 && ContinuousClock.now < seekDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completedSeeks, 1)
        XCTAssertEqual(position, 0.5, accuracy: 0.1)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        let resetDeadline = ContinuousClock.now + .seconds(5)
        while !resetReported && ContinuousClock.now < resetDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(resetReported)
        XCTAssertFalse(engine.wantsPlayback)
        XCTAssertFalse(engine.isPlaying)
        try engine.resume()
        let resumeDeadline = ContinuousClock.now + .seconds(5)
        while completedSeeks < 2 && ContinuousClock.now < resumeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completedSeeks, 2)
        XCTAssertGreaterThanOrEqual(position, 0.4)
        XCTAssertTrue(engine.wantsPlayback)
    }

    @MainActor
    func testObserverOwnerReleasesAfterClear() throws {
        let player = AVPlayer()
        var engine: PlaybackEngine? = PlaybackEngine(player: player)
        weak let weakEngine = engine
        engine?.clear()
        engine = nil
        XCTAssertNil(weakEngine, "Observer callbacks must not retain their owner")
    }
}
