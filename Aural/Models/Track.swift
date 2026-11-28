import Foundation

struct Track: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var file: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var favorite = false
    var artwork: String? = nil
    var contentHash: String? = nil
    var metadata: TrackMetadata? = nil
    var artworkHash: String? = nil

    // Older indexes used the display label as a sentinel. New imports record the tag's presence.
    var hasAlbumTag: Bool? = nil
    var isSingle: Bool { !(hasAlbumTag ?? (album != "Unknown album")) }

    var albumArtist: String { metadata?.albumArtist ?? artist }
    var format: String { URL(fileURLWithPath: file).pathExtension.uppercased() }
}
