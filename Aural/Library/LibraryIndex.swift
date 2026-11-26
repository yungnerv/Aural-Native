import Foundation

struct LibraryIndex: Sendable {
    struct Group: Identifiable, Sendable {
        struct Key: Hashable, Sendable {
            let category: String
            let album: String
            let artist: String
            let single: UUID?
        }
        let id: Key
        let title: String
        let subtitle: String
        let tracks: [Track]
    }

    let tracks: [Track]
    let byID: [UUID: Track]
    private let searchable: [UUID: String]
    private let albums: [Group]
    private let artists: [Group]
    private let groupsByKey: [Group.Key: Group]

    init(_ tracks: [Track]) {
        self.tracks = tracks
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        searchable = Dictionary(tracks.map { ($0.id, "\($0.title) \($0.artist) \($0.album)") }, uniquingKeysWith: { first, _ in first })
        albums = Self.makeGroups(tracks, category: "Albums")
        artists = Self.makeGroups(tracks, category: "Artists")
        groupsByKey = Dictionary(uniqueKeysWithValues: (albums + artists).map { ($0.id, $0) })
    }

    func filter(_ query: String, favoritesOnly: Bool = false) -> [Track] {
        if query.isEmpty && !favoritesOnly { return tracks }
        return tracks.filter {
            (!favoritesOnly || $0.favorite) &&
            (query.isEmpty || searchable[$0.id]?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    func group(for key: Group.Key) -> Group? { groupsByKey[key] }

    func groups(category: String, query: String) -> [Group] {
        if query.isEmpty { return category == "Artists" ? artists : albums }
        return Self.makeGroups(filter(query), category: category)
    }

    private static func makeGroups(_ tracks: [Track], category: String) -> [Group] {
        let grouped = Dictionary(grouping: tracks) { track -> Group.Key in
            if category == "Artists" { return .init(category: category, album: "", artist: track.artist, single: nil) }
            return .init(category: category, album: track.album, artist: track.artist, single: track.album == "Unknown album" ? track.id : nil)
        }
        return grouped.compactMap { key, songs in
            guard let first = songs.first else { return nil }
            let title = category == "Artists" ? first.artist : (key.single == nil ? first.album : first.title)
            return Group(id: key, title: title, subtitle: category == "Artists" ? "\(songs.count) songs" : first.artist, tracks: songs)
        }.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let subtitleOrder = $0.subtitle.localizedStandardCompare($1.subtitle)
            if subtitleOrder != .orderedSame { return subtitleOrder == .orderedAscending }
            if $0.title != $1.title { return $0.title < $1.title }
            if $0.subtitle != $1.subtitle { return $0.subtitle < $1.subtitle }
            return ($0.tracks.first?.id.uuidString ?? "") < ($1.tracks.first?.id.uuidString ?? "")
        }
    }
}
