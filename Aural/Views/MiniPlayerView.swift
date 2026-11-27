import SwiftUI

/// The system supplies the Liquid Glass accessory surface. Do not layer a
/// second custom material underneath it.
struct MiniPlayerView: View {
    let track: Track
    let openPlayer: () -> Void

    @EnvironmentObject private var store: MusicStore
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.dynamicTypeSize) private var typeSize

    private var compact: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: compact ? 4 : 10) {
            Button(action: openPlayer) {
                HStack(spacing: 8) {
                    Cover(url: store.artworkURL(track))
                        .frame(width: compact ? 30 : 40, height: compact ? 30 : 40)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !compact && !typeSize.isAccessibilitySize {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
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

            if !compact && !typeSize.isAccessibilitySize {
                Button { store.advance(1) } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
                .disabled(!store.canAdvance)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 4 : 12)
    }
}
