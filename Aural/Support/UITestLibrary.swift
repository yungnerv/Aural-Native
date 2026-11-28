#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// Synthetic simulator fixture. Compiled out of release builds. Uses a unique
/// temporary root, never the user's real library, and never writes their files.
enum UITestLibrary {
    @MainActor static func prepare() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(
            "aural-ui-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let id = UUID(uuidString: "1A2B3C4D-0001-4000-8000-000000000001")!
        let name = "\(id.uuidString).wav"
        let file = root.appendingPathComponent(name)
        let seconds = 180
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
        var track = Track(
            id: id, file: name, title: "Aural Test Track", artist: "Fixture Artist",
            album: "Fixture Album", duration: Double(seconds),
            contentHash: try FileDigest.sha256(file)
        )
        let albums = ["Fixture Album", "Night Signal", "Quiet Water"]
        let artists = ["Fixture Artist", "Mira Vale", "Northline"]
        let titles = ["Aural Test Track", "Afterglow", "Blue Hour", "Crossfade", "Low Tide", "Open Water"]
        let colors: [UIColor] = [.systemIndigo, .systemOrange, .systemTeal]
        var tracks: [Track] = []
        for (i, title) in titles.enumerated() {
            let album = i / 2
            if i > 0 {
                track.id = UUID()
                track.file = "\(track.id.uuidString).wav"
                try FileManager.default.linkItem(at: file, to: root.appendingPathComponent(track.file))
            }
            track.title = title
            track.album = albums[album]
            track.artist = artists[album]
            track.favorite = i.isMultiple(of: 2)
            let artwork = "\(track.id.uuidString)-cover.jpg"
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 180))
            let jpeg = renderer.jpegData(withCompressionQuality: 0.9) { context in
                colors[album].setFill()
                context.fill(CGRect(x: 0, y: 0, width: 180, height: 180))
                UIColor.white.withAlphaComponent(0.35).setFill()
                for j in 0...2 {
                    context.cgContext.fillEllipse(in: CGRect(x: 30 * j - 50, y: 24 * album + 18 * j,
                                                             width: 150, height: 150))
                }
            }
            try jpeg.write(to: root.appendingPathComponent(artwork))
            track.artwork = artwork
            track.artworkHash = FileDigest.sha256(jpeg)
            tracks.append(track)
        }
        // Fixture initialization only; normal application persistence remains
        // exclusively owned by LibraryRepository.
        let snapshot = LibraryRepository.Snapshot(schemaVersion: 2, tracks: tracks)
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        return root
    }
}
#endif
