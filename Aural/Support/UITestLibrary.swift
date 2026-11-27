#if DEBUG
import AVFoundation
import Foundation

/// Synthetic simulator fixture. Compiled out of release builds. Uses a unique
/// temporary root, never the user's real library, and never writes their files.
enum UITestLibrary {
    static func prepare() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(
            "aural-ui-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let id = UUID(uuidString: "1A2B3C4D-0001-4000-8000-000000000001")!
        let name = "\(id.uuidString).wav"
        let file = root.appendingPathComponent(name)
        let seconds = 60
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410),
              let samples = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }

        buffer.frameLength = 4_410
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0
        }
        do {
            let output = try AVAudioFile(forWriting: file, settings: format.settings)
            for _ in 0..<(seconds * 10) {
                try output.write(from: buffer)
            }
        }
        let track = Track(
            id: id, file: name, title: "Aural Test Track", artist: "Fixture Artist",
            album: "Fixture Album", duration: Double(seconds),
            contentHash: try FileDigest.sha256(file)
        )
        // Fixture initialization only; normal application persistence remains
        // exclusively owned by LibraryRepository.
        let snapshot = LibraryRepository.Snapshot(schemaVersion: 2, tracks: [track])
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        return root
    }
}
#endif
