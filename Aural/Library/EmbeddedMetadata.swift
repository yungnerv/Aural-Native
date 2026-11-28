import AVFoundation
import Foundation

/// AVFoundation-only extraction. Platform-specific tag mappings do not leak into
/// storage or library grouping. The importer never rewrites the source tags.
enum EmbeddedMetadata {
    static func read(
        _ items: [AVMetadataItem], filename: String, isolation: isolated (any Actor)? = #isolation
    ) async throws -> TrackMetadata {
        var result = TrackMetadata()
        result.albumArtist = await text(items, [.iTunesMetadataAlbumArtist, .id3MetadataBand])
        result.composer = await text(items, [.iTunesMetadataComposer, .id3MetadataComposer])
        result.genre = await text(items, [.iTunesMetadataUserGenre, .id3MetadataContentType])
        result.releaseDate = await text(items, [.iTunesMetadataReleaseDate, .id3MetadataReleaseTime])
        result.recordingDate = await text(items, [.id3MetadataRecordingTime, .id3MetadataYear])
        result.track = await position(items, textID: .id3MetadataTrackNumber, binaryID: .iTunesMetadataTrackNumber)
        result.disc = await position(items, textID: .id3MetadataPartOfASet, binaryID: .iTunesMetadataDiscNumber)
        result.originalFilename = filename
        try Task.checkCancellation()
        return result
    }

    private static func text(
        _ items: [AVMetadataItem], _ identifiers: [AVMetadataIdentifier],
        isolation: isolated (any Actor)? = #isolation
    ) async -> String? {
        for identifier in identifiers {
            for item in items where item.identifier == identifier {
                if let value = TrackMetadata.cleanText(try? await item.load(.stringValue)) {
                    return value
                }
            }
        }
        return nil
    }

    private static func position(
        _ items: [AVMetadataItem], textID: AVMetadataIdentifier, binaryID: AVMetadataIdentifier,
        isolation: isolated (any Actor)? = #isolation
    ) async -> TrackMetadata.Position? {
        if let value = await text(items, [textID]),
           let position = TrackMetadata.Position.parse(value) {
            return position
        }
        for item in items where item.identifier == binaryID {
            if let data = try? await item.load(.dataValue),
               let position = TrackMetadata.Position.parseITunes(data) {
                return position
            }
            if let value = TrackMetadata.cleanText(try? await item.load(.stringValue)),
               let position = TrackMetadata.Position.parse(value) {
                return position
            }
        }
        return nil
    }
}
