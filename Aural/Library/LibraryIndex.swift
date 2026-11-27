import Foundation

enum LibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case albums = "Albums"
    case artists = "Artists"
    case songs = "Songs"

    var id: Self { self }
}

struct LibraryIndex: Sendable {
    let revision = UUID()
    struct Group: Identifiable, Sendable {
        struct Key: Hashable, Sendable {
            let category: LibraryCategory
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
    let favorites: [Track]
    subscript(id: UUID) -> Track? { positionByID[id].map { tracks[$0] } }
    let positionByID: [UUID: Int]
    private let searchable: [UUID: String]
    private let albums: [Group]
    private let artists: [Group]
    private let groupsByKey: [Group.Key: Group]

    init(_ tracks: [Track]) {
        self.tracks = tracks
        favorites = tracks.filter(\.favorite)
        positionByID = Dictionary(tracks.enumerated().lazy.map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        searchable = Dictionary(tracks.lazy.map { track in
            let extra = [track.metadata?.albumArtist, track.metadata?.composer, track.metadata?.genre,
                         track.metadata?.releaseDate, track.metadata?.recordingDate].compactMap { $0 }
            return (track.id, ([track.title, track.artist, track.album] + extra).joined(separator: " "))
        }, uniquingKeysWith: { first, _ in first })
        albums = Self.makeGroups(tracks, category: .albums)
        artists = Self.makeGroups(tracks, category: .artists)
        groupsByKey = Dictionary(uniqueKeysWithValues: (albums + artists).map { ($0.id, $0) })
    }

    func filter(_ query: String, favoritesOnly: Bool = false) -> [Track] {
        let source = favoritesOnly ? favorites : tracks
        guard !query.isEmpty else { return source }
        return source.filter {
            searchable[$0.id]?.localizedCaseInsensitiveContains(query) == true
        }
    }

    func group(for key: Group.Key) -> Group? { groupsByKey[key] }

    func groups(category: LibraryCategory, query: String) -> [Group] {
        guard category != .songs else { return [] }
        if query.isEmpty { return category == .artists ? artists : albums }
        return Self.makeGroups(filter(query), category: category)
    }

    struct SearchResult: Sendable {
        let tracks: [Track]
        let groups: [Group]
    }

    /// Search immutable snapshots independently of UI state.
    func search(_ query: String, category: LibraryCategory) throws -> SearchResult {
        try Task.checkCancellation()
        if query.isEmpty {
            return SearchResult(tracks: tracks, groups: category == .songs ? [] : (category == .artists ? artists : albums))
        }
        var matches: [Track] = []
        for (offset, track) in tracks.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            if searchable[track.id]?.localizedCaseInsensitiveContains(query) == true {
                matches.append(track)
            }
        }
        try Task.checkCancellation()
        let groups = category == .songs ? [] : Self.makeGroups(matches, category: category)
        try Task.checkCancellation()
        return SearchResult(tracks: matches, groups: groups)
    }

    private static func makeGroups(_ tracks: [Track], category: LibraryCategory) -> [Group] {
        let grouped = Dictionary(grouping: tracks) { track -> Group.Key in
            if category == .artists { return .init(category: category, album: "", artist: track.artist, single: nil) }
            return .init(category: category, album: track.album, artist: track.albumArtist, single: track.album == "Unknown album" ? track.id : nil)
        }
        return grouped.compactMap { key, songs in
            guard let first = songs.first else { return nil }
            let title = category == .artists ? first.artist : (key.single == nil ? first.album : first.title)
            // Disc and track order are stable; unnumbered tracks retain import order.
            let ordered = category == .albums ? songs.enumerated().sorted { lhs, rhs in
                let leftDisc = lhs.element.metadata?.disc?.number ?? 1
                let rightDisc = rhs.element.metadata?.disc?.number ?? 1
                if leftDisc != rightDisc { return leftDisc < rightDisc }
                let leftTrack = lhs.element.metadata?.track?.number ?? Int.max
                let rightTrack = rhs.element.metadata?.track?.number ?? Int.max
                if leftTrack != rightTrack { return leftTrack < rightTrack }
                return lhs.offset < rhs.offset
            }.map(\.element) : songs
            return Group(id: key, title: title, subtitle: category == .artists ? "\(songs.count) songs" : key.artist, tracks: ordered)
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
