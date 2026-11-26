import Foundation
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

actor AudioImporter {
    func digest(_ url: URL) throws -> String { try FileDigest.sha256(url) }

    func readFile(_ url: URL, into root: URL, knownHashes: Set<String>) async throws -> Track? {
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
            let properties = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
                throw NSError(domain: "Aural.Import", code: 2, userInfo: [NSLocalizedDescriptionKey: "Only regular audio files can be imported."])
            }
            let digest = try FileDigest.sha256(destination)
            if knownHashes.contains(digest) { try fm.removeItem(at: destination); return nil }
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            return Track(id: id, file: name, title: title, artist: artist, album: album, duration: d.isFinite ? max(0,d) : 0, artwork: artName, contentHash: digest)
        } catch { try? fm.removeItem(at: destination); if let artName { try? fm.removeItem(at: root.appendingPathComponent(artName)) }; throw error }
    }
    private func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1000, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }; return output as Data
    }
}
