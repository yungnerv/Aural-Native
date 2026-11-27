import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor AudioImporter {
    private enum Failure: LocalizedError {
        case invalidSource
        case unsupportedAudio
        case cleanup(String, [String])

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                return "Only regular audio files can be imported."
            case .unsupportedAudio:
                return "Unsupported audio format or damaged file."
            case let .cleanup(reason, errors):
                return "\(reason) Cleanup incomplete: \(errors.joined(separator: "; ")). Existing files are preserved."
            }
        }
    }

    func digest(_ url: URL) throws -> String {
        try requireRegularFile(url)
        return try FileDigest.sha256(url)
    }

    func readFile(_ url: URL, into root: URL, knownHashes: Set<String>) async throws -> Track? {
        let fm = FileManager.default
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        try requireRegularFile(url)
        let id = UUID()
        let extensionName = url.pathExtension.lowercased()
        let name = extensionName.isEmpty ? id.uuidString : "\(id.uuidString).\(extensionName)"
        let art = "\(id.uuidString)-cover.jpg"
        let staging = root.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        let stagedAudio = staging.appendingPathComponent(name)
        let stagedArt = staging.appendingPathComponent(art)
        let destination = root.appendingPathComponent(name)
        let artworkDestination = root.appendingPathComponent(art)
        // Staging is private to this invocation. Never remove a pre-existing final path.
        guard !fm.fileExists(atPath: staging.path),
              (try? fm.destinationOfSymbolicLink(atPath: staging.path)) == nil else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var published: [URL] = []

        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                do {
                    try requireRegularFile(readable)
                    try FileManager.default.copyItem(at: readable, to: stagedAudio)
                } catch {
                    copyError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }

            let hash = try digest(stagedAudio)
            if knownHashes.contains(hash) {
                try fm.removeItem(at: staging)
                return nil
            }
            try Task.checkCancellation()

            let asset = AVURLAsset(url: stagedAudio)
            let playable = try await asset.load(.isPlayable)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard playable, !audio.isEmpty else { throw Failure.unsupportedAudio }
            let duration = try await asset.load(.duration).seconds
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            func value(_ key: AVMetadataKey) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: .common).first else {
                    return nil
                }
                return try? await item.load(.stringValue)
            }

            let filename = url.deletingPathExtension().lastPathComponent
            let parts = filename.components(separatedBy: " - ")
            let title = await value(.commonKeyTitle) ?? (parts.count == 2 ? parts[1] : filename)
            let artist = await value(.commonKeyArtist) ?? (parts.count == 2 ? parts[0] : "Unknown artist")
            let album = await value(.commonKeyAlbumName) ?? "Unknown album"
            var artName: String?
            if let item = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
               let data = try? await item.load(.dataValue), data.count <= 20_000_000,
               let jpeg = thumbnail(data) {
                try jpeg.write(to: stagedArt, options: .atomic)
                artName = art
            }
            try Task.checkCancellation()

            // moveItem refuses an existing destination; ownership begins only on success.
            try fm.moveItem(at: stagedAudio, to: destination)
            published.append(destination)
            if artName != nil {
                try fm.moveItem(at: stagedArt, to: artworkDestination)
                published.append(artworkDestination)
            }
            try fm.removeItem(at: staging)
            return Track(id: id, file: name, title: title, artist: artist, album: album,
                         duration: duration.isFinite ? max(0, duration) : 0,
                         artwork: artName, contentHash: hash)
        } catch {
            var failures: [String] = []
            for path in published + [staging] {
                guard fm.fileExists(atPath: path.path) else { continue }
                do { try fm.removeItem(at: path) }
                catch { failures.append("\(path.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { throw Failure.cleanup(error.localizedDescription, failures) }
            throw error
        }
    }

    private nonisolated func requireRegularFile(_ url: URL) throws {
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw Failure.invalidSource
        }
    }

    private func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1000,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
