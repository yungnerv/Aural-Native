import Combine

@MainActor final class PlaybackClock: ObservableObject {
    @Published var elapsed = 0.0
    @Published var duration = 0.0
}
