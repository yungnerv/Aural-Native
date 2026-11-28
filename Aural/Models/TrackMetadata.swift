import Foundation

/// Optional embedded tags. Missing information stays missing; no inferred dates
/// or invented track numbers. Metadata can evolve independently of audio bytes.
struct TrackMetadata: Codable, Hashable, Sendable {
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var releaseDate: String?
    var recordingDate: String?
    var track: Position?
    var disc: Position?
    var originalFilename: String?

    struct Position: Codable, Hashable, Sendable {
        let number: Int
        let total: Int?

        init?(number: Int, total: Int? = nil) {
            guard number > 0, total.map({ $0 >= number }) ?? true else { return nil }
            self.number = number
            self.total = total
        }

        var isValid: Bool {
            number > 0 && (total.map { $0 >= number } ?? true)
        }

        /// ID3 convention: "7" or "7/12".
        static func parse(_ text: String) -> Self? {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  let number = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            if parts.count == 1 { return Self(number: number) }
            guard let total = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return Self(number: number, total: total == 0 ? nil : total)
        }

        /// iTunes trkn/disk data payload: reserved UInt16, index, total,
        /// and optionally a reserved UInt16. Reject unrecognized payloads.
        static func parseITunes(_ data: Data) -> Self? {
            guard data.count == 6 || data.count == 8 else { return nil }
            let bytes = Array(data)
            guard bytes[0] == 0, bytes[1] == 0,
                  bytes.count == 6 || (bytes[6] == 0 && bytes[7] == 0) else { return nil }
            let number = Int(bytes[2]) * 256 + Int(bytes[3])
            let total = Int(bytes[4]) * 256 + Int(bytes[5])
            return Self(number: number, total: total == 0 ? nil : total)
        }
    }

    static func cleanText(_ text: String?) -> String? {
        guard let text else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
