import SwiftUI

struct PlaybackProgressView: View {
    @ObservedObject var progress: PlaybackClock
    let trackID: UUID
    let seek: (UUID, Double) -> Void
    @State private var dragTrackID: UUID?
    @State private var seekValue = 0.0

    private var upperBound: Double {
        max(progress.duration.isFinite ? progress.duration : 0, 1)
    }

    private var displayedValue: Double {
        let value = dragTrackID == nil ? progress.elapsed : seekValue
        return min(max(value.isFinite ? value : 0, 0), upperBound)
    }

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(get: { displayedValue }, set: { seekValue = $0 }),
                in: 0...upperBound,
                onEditingChanged: { active in
                    if active {
                        dragTrackID = trackID
                        seekValue = displayedValue
                    } else {
                        if dragTrackID == trackID { seek(trackID, displayedValue) }
                        dragTrackID = nil
                    }
                }
            )
            .disabled(progress.duration <= 0 || !progress.duration.isFinite)
            .accessibilityLabel("Playback position")
            HStack {
                Text(clock(displayedValue))
                Spacer()
                Text(clock(progress.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: trackID) { _, _ in
            dragTrackID = nil
            seekValue = 0
        }
    }

    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, min(value.isFinite ? value : 0, 999999)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
