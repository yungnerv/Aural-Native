import SwiftUI

struct TrackList: View {
    let songs: [Track]
    @EnvironmentObject private var store: MusicStore

    var body: some View {
        List(songs) { track in
            let selected = store.currentID == track.id
            let favorite = store.index[track.id]?.favorite ?? track.favorite
            Button {
                store.play(track, in: songs)
            } label: {
                HStack(spacing: 12) {
                    Cover(url: store.artworkURL(track))
                        .frame(width: 46, height: 46)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "waveform")
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                    }
                }
                // Plain buttons do not automatically hit-test empty Spacer
                // regions. The entire row, not just text and artwork, is a
                // playback target on wide screens and in narrow windows.
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .accessibilityLabel("\(track.title), \(track.artist)")
            .accessibilityIdentifier("track-\(track.id.uuidString)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .disabled(!store.libraryReady)
            .swipeActions {
                Button { store.favorite(track) } label: {
                    Label(favorite ? "Remove favorite" : "Favorite",
                          systemImage: favorite ? "heart.slash" : "heart")
                }
                .tint(.blue)
                .disabled(store.mutationBusy || !store.libraryReady)
            }
            .contextMenu {
                Button { store.favorite(track) } label: {
                    Label(favorite ? "Remove favorite" : "Favorite", systemImage: "heart")
                }
                .disabled(store.mutationBusy || !store.libraryReady)
                Button(role: .destructive) { store.remove(track) } label: {
                    Label("Remove from Aural", systemImage: "trash")
                }
                .disabled(store.mutationBusy || !store.libraryReady)
            }
        }
        .listStyle(.plain)
    }
}
