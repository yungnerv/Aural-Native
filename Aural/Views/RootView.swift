import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var store: MusicStore
    @State private var tab = 0
    @State private var category = "Albums"
    @State private var search = ""
    @State private var showFiles = false
    @State private var showPlayer = false
    @State private var confirmRecovery = false
    var filtered: [Track] { store.index.filter(search) }
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { library }.tabItem { Label("Library", systemImage: "books.vertical") }.tag(0)
            NavigationStack { favorites.navigationTitle("Favorites") }.tabItem { Label("Favorites", systemImage: "heart") }.tag(1)
            NavigationStack { Form { Section("Aural Native") { Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")"); Text("Local playback · No accounts or streaming"); Text("Files are copied into Aural's private storage. Keep your originals.") }; Section("Library") { Text("\(store.tracks.count) tracks"); Button("Add music") { showFiles = true }.disabled(!store.libraryReady || store.mutationBusy) } }.navigationTitle("Settings") }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .tint(.mint)
        .tabViewBottomAccessory(isEnabled: store.current != nil) { if let track = store.current { mini(track) } }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): Task { await store.importFiles(urls) }; case .failure(let error): store.message = error.localizedDescription }
        }
        .sheet(isPresented: $showPlayer) { PlayerView(progress: store.clock).environmentObject(store) }
        .confirmationDialog("Restore previous library index?", isPresented: $confirmRecovery, titleVisibility: .visible) {
            Button("Restore previous index") { store.restoreLibrary() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The current damaged index will be preserved. The previous index may omit recent library changes. No audio files will be deleted.") }
        .alert("Aural", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("OK") { store.message = nil } } message: { Text(store.message ?? "") }
    }
    var library: some View {
        VStack(spacing: 0) {
            Picker("Library view", selection: $category) { ForEach(["Albums","Artists","Songs"], id: \.self) { Text($0) } }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            if store.importing { ProgressView("Importing music…").padding(6) }
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
            else if filtered.isEmpty { ContentUnavailableView.search(text: search) }
            else if category == "Songs" { trackList(filtered) }
            else { groups }
        }.navigationTitle("Library").searchable(text: $search, prompt: "Search your music").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showFiles = true } label: { Label("Add music", systemImage: "plus") }.disabled(!store.libraryReady || store.mutationBusy) } }
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
        let groups = store.index.groups(category: category, query: search)
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
            }.buttonStyle(.plain).swipeActions { Button { store.favorite(track) } label: { Label(track.favorite ? "Remove favorite" : "Favorite", systemImage: track.favorite ? "heart.slash" : "heart") }.tint(.mint).disabled(store.mutationBusy || !store.libraryReady) }.contextMenu { Button { store.favorite(track) } label: { Label(track.favorite ? "Remove favorite" : "Favorite", systemImage: "heart") }.disabled(store.mutationBusy || !store.libraryReady); Button(role: .destructive) { store.remove(track) } label: { Label("Remove from Aural", systemImage: "trash") }.disabled(store.mutationBusy || !store.libraryReady) }
        }.listStyle(.plain)
    }
    func mini(_ track: Track) -> some View {
        HStack(spacing: 10) {
            Button { showPlayer = true } label: { HStack(spacing: 10) { Cover(url: store.artworkURL(track)).frame(width: 40,height: 40); VStack(alignment: .leading,spacing: 3) { Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(minLength: 0) }.foregroundStyle(.primary) }.buttonStyle(.plain)
            Button { store.toggle() } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill").frame(width:44,height:44) }.accessibilityLabel(store.playing ? "Pause" : "Play").disabled(!store.canToggle)
            Button { store.advance(1) } label: { Image(systemName: "forward.end.fill").frame(width:44,height:44) }.accessibilityLabel("Next track").disabled(!store.canAdvance)
        }.padding(.horizontal, 12).foregroundStyle(.primary)
    }
}
