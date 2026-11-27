import SwiftUI

struct PlaybackProgressView: View {
    @ObservedObject var progress: PlaybackClock
    let revision: Int
    let seek: (Int, Double) -> Void
    @State private var editing = false
    @State private var seekValue = 0.0

    private var upperBound: Double {
        progress.duration.isFinite && progress.duration > 0 ? progress.duration : 1
    }

    private var displayedValue: Double {
        let value = editing ? seekValue : progress.elapsed
        return min(max(value.isFinite ? value : 0, 0), upperBound)
    }

    var body: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(get: { displayedValue }, set: { value in
                    if editing { seekValue = value }
                    else { seek(revision, value) }
                }),
                in: 0...upperBound,
                onEditingChanged: { active in
                    if active {
                        seekValue = displayedValue
                        editing = true
                    } else if editing {
                        let value = displayedValue
                        editing = false
                        seek(revision, value)
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
    }

    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, min(value.isFinite ? value : 0, 999999)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
