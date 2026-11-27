import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var store: MusicStore
    private enum Destination: Hashable {
        case albums, artists, songs, favorites, settings
    }

    @State private var tab = Destination.albums
    @State private var showFiles = false
    @State private var showPlayer = false
    @State private var confirmRecovery = false
    var body: some View {
        TabView(selection: $tab) {
            Tab("Albums", systemImage: "square.stack", value: Destination.albums) {
                browser(.albums, destination: .albums)
            }
            Tab("Artists", systemImage: "music.mic", value: Destination.artists) {
                browser(.artists, destination: .artists)
            }
            Tab("Songs", systemImage: "music.note.list", value: Destination.songs) {
                browser(.songs, destination: .songs)
            }
            Tab("Favorites", systemImage: "heart", value: Destination.favorites) {
                tabContent(.favorites) { favorites.navigationTitle("Favorites") }
            }
            Tab("Settings", systemImage: "gearshape", value: Destination.settings) {
                tabContent(.settings) { settings }
            }
        }
        .tint(.mint)
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
    /// One stable mini-player host in the selected navigation tab, on both
    /// device families. The navigation safe area accounts for native tab bars;
    /// the content does not depend on an accessory controller's activation point.
    private func tabContent<Content: View>(
        _ selection: Destination, @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack { content() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if tab == selection, let track = store.current {
                    MiniPlayerView(track: track) { showPlayer = true }
                        .padding(.vertical, 6)
                        .frame(maxWidth: 600)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 21)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                }
            }
    }

    private func browser(_ category: LibraryCategory, destination: Destination) -> some View {
        tabContent(destination) {
            LibraryBrowser(category: category, showFiles: $showFiles, confirmRecovery: $confirmRecovery)
        }
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
                                       description: Text("Reopen the library from Albums, Artists, or Songs."))
            } else {
                let songs = store.index.favorites
                if songs.isEmpty {
                    ContentUnavailableView("No favorites", systemImage: "heart", description: Text("Mark a song as a favorite to see it here."))
                } else {
                    TrackList(songs: songs)
                }
            }
        }
    }

}
