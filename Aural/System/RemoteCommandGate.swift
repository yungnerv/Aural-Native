import Foundation
import Synchronization

/// Remote callbacks may arrive on a background thread. The mutex protects a
/// small value-only snapshot; the playback engine remains main-actor isolated.
final class RemoteCommandGate: Sendable {
    enum Command: Hashable, Sendable {
        case play, pause, next, previous, seek
    }

    private struct State: Sendable {
        var trackID: UUID?
        var available: Set<Command> = []
    }

    private let state = Mutex(State())

    func update(trackID: UUID?, available: Set<Command>) {
        state.withLock { $0 = State(trackID: trackID, available: available) }
    }

    func accept(_ command: Command) -> UUID? {
        state.withLock { $0.available.contains(command) ? $0.trackID : nil }
    }

    func isCurrent(_ id: UUID, command: Command) -> Bool {
        state.withLock { $0.trackID == id && $0.available.contains(command) }
    }
}
