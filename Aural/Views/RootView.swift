import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var store: MusicStore
    @State private var tab = 0
    @State private var category = LibraryCategory.albums
    @State private var search = ""
    @State private var showFiles = false
    @State private var showPlayer = false
    @State private var confirmRecovery = false
    private struct SearchKey: Equatable, Sendable {
        let revision: UUID
        let category: LibraryCategory
        let query: String
    }

    private struct SearchSnapshot {
        let key: SearchKey
        let result: LibraryIndex.SearchResult
    }

    @State private var searchSnapshot: SearchSnapshot?

    private var searchKey: SearchKey {
        SearchKey(revision: store.index.revision, category: category, query: search)
    }

    private var matchingResult: LibraryIndex.SearchResult? {
        guard searchSnapshot?.key == searchKey else { return nil }
        return searchSnapshot?.result
    }

    private var filtered: [Track] {
        search.isEmpty ? store.tracks : matchingResult?.tracks ?? []
    }
    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "books.vertical", value: 0) {
                NavigationStack { library }
            }
            Tab("Favorites", systemImage: "heart", value: 1) {
                NavigationStack { favorites.navigationTitle("Favorites") }
            }
            Tab("Settings", systemImage: "gearshape", value: 2) {
                NavigationStack { settings }
            }
        }
        .tint(.mint)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: store.current != nil) {
            if let track = store.current {
                MiniPlayerView(track: track) { showPlayer = true }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): store.beginImport(urls); case .failure(let error): store.message = error.localizedDescription }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView(progress: store.clock)
                .environmentObject(store)
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Restore previous library index?", isPresented: $confirmRecovery, titleVisibility: .visible) {
            Button("Restore previous index") { store.restoreLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The current damaged index will be preserved. The previous index may omit recent library changes. No audio files will be deleted.") }
        .alert("Aural", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("OK") { store.message = nil } } message: { Text(store.message ?? "") }
    }
    var library: some View {
        VStack(spacing: 0) {
            Picker("Library view", selection: $category) {
                ForEach(LibraryCategory.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library-category")
            .padding(.horizontal)
            .padding(.vertical, 8)
            if store.importing {
                HStack(spacing: 12) {
                    ProgressView(value: store.importProgress) {
                        Text("Importing music…")
                    }
                    Button("Cancel", role: .cancel) { store.cancelImport() }
                        .font(.subheadline)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if store.libraryLoading { ProgressView("Opening library…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !store.libraryReady {
                ContentUnavailableView {
                    Label("Library unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    if let report = store.recoveryReport {
                        Text("Previous index: \(report.tracks) tracks, \(report.missingMedia) missing files, \(report.unreferencedFiles) unreferenced files. Existing files are protected.")
                    } else {
                        Text("Existing files are protected. No changes can be made.")
                    }
                } actions: {
                    Button("Reopen library") { store.retryLibrary() }.disabled(store.mutationBusy)
                    if store.recoveryReport?.canRestore == true {
                        Button("Restore previous index…") { confirmRecovery = true }.disabled(store.mutationBusy)
                    }
                }
            }
            else if store.tracks.isEmpty { ContentUnavailableView("No music", systemImage: "music.note.list", description: Text("Add audio files from Files to get started.")) }
            else if !search.isEmpty && matchingResult == nil { ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if filtered.isEmpty { ContentUnavailableView.search(text: search) }
            else if category == .songs { trackList(filtered) }
            else { groups }
        }
        .task(id: searchKey) {
            let key = searchKey
            guard !key.query.isEmpty else { searchSnapshot = nil; return }
            let snapshot = store.index
            let worker = Task.detached(priority: .userInitiated) {
                try snapshot.search(key.query, category: key.category)
            }
            let result = await withTaskCancellationHandler {
                try? await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, key == searchKey, let result else { return }
            searchSnapshot = SearchSnapshot(key: key, result: result)
        }
        .navigationTitle("Library").searchable(text: $search, prompt: "Search your music").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showFiles = true } label: { Label("Add music", systemImage: "plus") }.disabled(!store.libraryReady || store.mutationBusy) } }
    }
    private var settings: some View {
        Form {
            Section("Aural Native") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
                Text("Version \(version) · Build \(build)")
                Text("Local playback · No accounts or streaming")
                Text("Files are copied into Aural's private storage. Keep your originals.")
            }
            Section("Library") {
                Text("\(store.tracks.count) tracks")
                Button("Add music") { showFiles = true }
                    .disabled(!store.libraryReady || store.mutationBusy)
                if !store.lastImportReport.isEmpty {
                    NavigationLink("Last import report") {
                        List {
                            ForEach(Array(store.lastImportReport.enumerated()), id: \.offset) { _, entry in
                                Text(entry)
                            }
                        }
                        .navigationTitle("Import report")
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var favorites: some View {
        Group {
            if store.libraryLoading {
                ProgressView("Opening library…")
            } else if !store.libraryReady {
                ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Reopen the library from the Library tab."))
            } else {
                let songs = store.index.filter("", favoritesOnly: true)
                if songs.isEmpty {
                    ContentUnavailableView("No favorites", systemImage: "heart", description: Text("Mark a song as a favorite to see it here."))
                } else {
                    trackList(songs)
                }
            }
        }
    }

    var groups: some View {
        let groups = search.isEmpty ? store.index.groups(category: category, query: "") : matchingResult?.groups ?? []
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 14)], spacing: 18) {
                ForEach(groups) { group in
                    if let first = group.tracks.first {
                        NavigationLink {
                            Group {
                                if store.libraryReady, let liveGroup = store.index.group(for: group.id) {
                                    trackList(liveGroup.tracks).navigationTitle(liveGroup.title)
                                } else {
                                    ContentUnavailableView("Group unavailable", systemImage: "music.note.list")
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Cover(url: store.artworkURL(first)).aspectRatio(1, contentMode: .fit)
                                Text(group.title).font(.headline).lineLimit(2)
                                Text(group.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }.foregroundStyle(.primary)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding()
        }
    }
    func trackList(_ songs: [Track]) -> some View {
        List(songs) { track in
            Button { store.play(track, in: songs) } label: {
                HStack(spacing: 12) { Cover(url: store.artworkURL(track)).frame(width: 46,height: 46); VStack(alignment: .leading, spacing: 4) { Text(track.title).foregroundStyle(.primary).lineLimit(1); Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if store.currentID == track.id { Image(systemName: "waveform").foregroundStyle(.mint) } }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("track-\(track.id.uuidString)")
            .swipeActions { Button { store.favorite(track) } label: { Label(track.favorite ? "Remove favorite" : "Favorite", systemImage: track.favorite ? "heart.slash" : "heart") }.tint(.mint).disabled(store.mutationBusy || !store.libraryReady) }.contextMenu { Button { store.favorite(track) } label: { Label(track.favorite ? "Remove favorite" : "Favorite", systemImage: "heart") }.disabled(store.mutationBusy || !store.libraryReady); Button(role: .destructive) { store.remove(track) } label: { Label("Remove from Aural", systemImage: "trash") }.disabled(store.mutationBusy || !store.libraryReady) }
        }.listStyle(.plain)
    }
}
