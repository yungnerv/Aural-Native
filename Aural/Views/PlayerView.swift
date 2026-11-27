import SwiftUI

struct PlayerView: View {
    let progress: PlaybackClock

    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if let track = store.current {
                    ScrollView {
                        Group {
                            if geometry.size.width >= 720 {
                                HStack(alignment: .center, spacing: 32) {
                                    artwork(track, size: min(geometry.size.width * 0.42, 440))
                                    details(track)
                                        .frame(minWidth: 280, maxWidth: 420)
                                }
                                .padding(24)
                            } else {
                                VStack(spacing: 24) {
                                    artwork(
                                        track,
                                        size: max(0, min(geometry.size.width - 40,
                                                        geometry.size.height * 0.62, 420))
                                    )
                                    details(track)
                                }
                                .frame(maxWidth: 520)
                                .padding(20)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    ContentUnavailableView("Nothing playing", systemImage: "music.note")
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("Close player", systemImage: "chevron.down")
                    }
                    .accessibilityIdentifier("close-player")
                }
            }
        }
        .tint(.mint)
    }

    private func artwork(_ track: Track, size: CGFloat) -> some View {
        Cover(url: store.artworkURL(track))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func details(_ track: Track) -> some View {
        VStack(spacing: 24) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("player-track-title")
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(track.format)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { store.favorite(track) } label: {
                    Image(systemName: track.favorite ? "heart.fill" : "heart")
                        .font(.title3)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(track.favorite ? .mint : .primary)
                .accessibilityLabel(track.favorite ? "Remove favorite" : "Favorite")
                .accessibilityAddTraits(track.favorite ? .isSelected : [])
                .disabled(store.mutationBusy || !store.libraryReady)
            }

            PlaybackProgressView(progress: progress, revision: store.playbackRevision) { revision, position in
                guard store.playbackRevision == revision else { return }
                store.seek(position)
            }
            .id(store.playbackRevision)
            .disabled(!store.libraryReady)

            transport
            modes
        }
    }

    /// Native glass styles handle interaction, accessibility contrast and
    /// reduced transparency. Only the control layer uses glass; art stays clear.
    private var transport: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Button { store.advance(-1) } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Previous")
                .disabled(!store.canGoBack)

                Button { store.toggle() } label: {
                    Image(systemName: store.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(.glassProminent)
                .tint(.mint)
                .accessibilityLabel(store.playing ? "Pause" : "Play")
                .accessibilityIdentifier("player-toggle")
                .disabled(!store.canToggle)

                Button { store.advance(1) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Next")
                .disabled(!store.canAdvance)
            }
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private var modes: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Button { store.toggleShuffle() } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .tint(store.shuffle ? .mint : .primary)
                .accessibilityLabel("Shuffle")
                .accessibilityAddTraits(store.shuffle ? .isSelected : [])

                Button { store.repeatOne.toggle() } label: {
                    Label("Repeat one", systemImage: store.repeatOne ? "repeat.1" : "repeat")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .tint(store.repeatOne ? .mint : .primary)
                .accessibilityLabel("Repeat one")
                .accessibilityAddTraits(store.repeatOne ? .isSelected : [])
            }
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
    }
}
