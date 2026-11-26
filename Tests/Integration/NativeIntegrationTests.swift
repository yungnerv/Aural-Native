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
        try engine.resume()
        XCTAssertFalse(engine.wantsPlayback)
    }
}
