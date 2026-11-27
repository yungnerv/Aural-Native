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

    var albumArtist: String { metadata?.albumArtist ?? artist }
    var format: String { URL(fileURLWithPath: file).pathExtension.uppercased() }
}
