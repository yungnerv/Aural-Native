import Foundation

struct Track: Codable, Identifiable, Hashable {
    var id = UUID()
    var file: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var favorite = false
    var artwork: String? = nil
    var format: String { URL(fileURLWithPath: file).pathExtension.uppercased() }
}
