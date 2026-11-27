import SwiftUI

/// Interactive content only. RootView supplies the single native Liquid Glass
/// surface; no nested material or separate playback state.
struct MiniPlayerView: View {
    let track: Track
    let openPlayer: () -> Void

    @EnvironmentObject private var store: MusicStore
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openPlayer) {
                HStack(spacing: 8) {
                    Cover(url: store.artworkURL(track))
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !typeSize.isAccessibilitySize {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Now Playing")
            .accessibilityValue("\(track.title), \(track.artist)")
            .accessibilityIdentifier("open-player")

            Button { store.toggle() } label: {
                Image(systemName: store.playing ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.playing ? "Pause" : "Play")
            .accessibilityIdentifier("mini-toggle")
            .disabled(!store.canToggle)

            if !typeSize.isAccessibilitySize {
                Button { store.advance(1) } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
                .accessibilityIdentifier("mini-next")
                .disabled(!store.canAdvance)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
    }
}
