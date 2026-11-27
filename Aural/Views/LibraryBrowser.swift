import SwiftUI

struct LibraryBrowser: View {
    let category: LibraryCategory
    @Binding var showFiles: Bool
    @Binding var confirmRecovery: Bool
    @EnvironmentObject private var store: MusicStore
    @State private var search = ""

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
        VStack(spacing: 0) {
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
                        Text("Previous index: \(report.tracks) tracks, \(report.missingMedia) missing or unsafe files, \(report.damagedMedia) damaged or unreadable files, \(report.unverifiedMedia) files without checksums, \(report.unreferencedFiles) unreferenced files. Existing files are protected.")
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
            else if category == .songs { TrackList(songs: filtered) }
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
        .navigationTitle(category.rawValue).searchable(text: $search, prompt: "Search your music").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showFiles = true } label: { Label("Add music", systemImage: "plus") }.disabled(!store.libraryReady || store.mutationBusy) } }
    }
    var groups: some View {
        let groups = search.isEmpty ? store.index.groups(category: category) : matchingResult?.groups ?? []
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 14)], spacing: 18) {
                ForEach(groups) { group in
                    if let first = group.tracks.first {
                        NavigationLink {
                            Group {
                                if store.libraryReady, let liveGroup = store.index.group(for: group.id) {
                                    TrackList(songs: liveGroup.tracks).navigationTitle(liveGroup.title)
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
}
