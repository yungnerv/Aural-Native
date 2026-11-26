import SwiftUI

struct PlaybackProgressView: View {
    @ObservedObject var progress: PlaybackClock
    let seek: (Double) -> Void
    @State private var dragging = false
    @State private var seekValue = 0.0
    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { dragging ? seekValue : min(progress.elapsed,max(progress.duration,1)) }, set: { seekValue = $0 }), in: 0...max(progress.duration,1), onEditingChanged: { active in if active { seekValue = progress.elapsed; dragging = true } else { seek(seekValue); dragging = false } }).accessibilityLabel("Playback position")
            HStack { Text(clock(dragging ? seekValue : progress.elapsed)); Spacer(); Text(clock(progress.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    func clock(_ value: Double) -> String { let s = Int(max(0,min(value.isFinite ? value : 0, 999999))); return String(format: "%d:%02d",s/60,s%60) }
}
