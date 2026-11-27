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
        fileprivate(set) var tracks: [Track]
    }

    private(set) var tracks: [Track]
    private(set) var favorites: [Track]
    subscript(id: UUID) -> Track? { positionByID[id].map { tracks[$0] } }
    let positionByID: [UUID: Int]
    private let searchable: [String]
    private var albums: [Group]
    private var artists: [Group]
    private let groupPositions: [Group.Key: Int]

    init(_ tracks: [Track]) {
        self.tracks = tracks
        favorites = tracks.filter(\.favorite)
        positionByID = Dictionary(tracks.enumerated().lazy.map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        searchable = tracks.map { track in
            let extra = [track.metadata?.albumArtist, track.metadata?.composer, track.metadata?.genre,
                         track.metadata?.releaseDate, track.metadata?.recordingDate].compactMap { $0 }
            return ([track.title, track.artist, track.album] + extra).joined(separator: " ")
        }
        albums = Self.makeGroups(tracks, category: .albums)
        artists = Self.makeGroups(tracks, category: .artists)
        var positions: [Group.Key: Int] = [:]
        for groups in [albums, artists] {
            for (i, group) in groups.enumerated() { positions[group.id] = i }
        }
        groupPositions = positions
    }

    func group(for key: Group.Key) -> Group? {
        groupPositions[key].map { groups(category: key.category)[$0] }
    }

    mutating func setFavorite(_ value: Bool, id: UUID) {
        guard let i = positionByID[id], tracks[i].favorite != value else { return }
        tracks[i].favorite = value
        let track = tracks[i]
        if value {
            let insertion = favorites.firstIndex { (positionByID[$0.id] ?? Int.max) > i }
            favorites.insert(track, at: insertion ?? favorites.endIndex)
        } else {
            favorites.removeAll { $0.id == id }
        }
        for category in [LibraryCategory.albums, .artists] {
            guard let group = groupPositions[Self.key(for: track, category: category)] else { continue }
            if category == .albums, let row = albums[group].tracks.firstIndex(where: { $0.id == id }) {
                albums[group].tracks[row] = track
            } else if category == .artists, let row = artists[group].tracks.firstIndex(where: { $0.id == id }) {
                artists[group].tracks[row] = track
            }
        }
    }

    func groups(category: LibraryCategory) -> [Group] {
        switch category {
        case .albums: albums
        case .artists: artists
        case .songs: []
        }
    }

    struct SearchResult: Sendable {
        let tracks: [Track]
        let groups: [Group]
    }

    /// Search immutable snapshots independently of UI state.
    func search(_ query: String, category: LibraryCategory) throws -> SearchResult {
        try Task.checkCancellation()
        if query.isEmpty {
            return SearchResult(tracks: tracks, groups: groups(category: category))
        }
        var matches: [Track] = []
        var matchedGroups = Set<Group.Key>()
        for offset in searchable.indices {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            if searchable[offset].localizedCaseInsensitiveContains(query) {
                let track = tracks[offset]
                matches.append(track)
                if category != .songs { matchedGroups.insert(Self.key(for: track, category: category)) }
            }
        }
        let results = try groups(category: category).filter {
            try Task.checkCancellation()
            return matchedGroups.contains($0.id)
        }
        return SearchResult(tracks: matches, groups: results)
    }

    private static func key(for track: Track, category: LibraryCategory) -> Group.Key {
        if category == .artists { return .init(category: category, album: "", artist: track.artist, single: nil) }
        return .init(category: category, album: track.album, artist: track.albumArtist, single: track.isSingle ? track.id : nil)
    }

    private static func makeGroups(_ tracks: [Track], category: LibraryCategory) -> [Group] {
        Dictionary(grouping: tracks) { key(for: $0, category: category) }.compactMap { key, songs in
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
            return Group(id: key, title: title, subtitle: category == .artists ? (songs.count == 1 ? "1 song" : "\(songs.count) songs") : key.artist, tracks: ordered)
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
