import Foundation
import Synchronization

/// Remote callbacks may arrive on a background thread. The mutex protects a
/// small value-only snapshot; the playback engine remains main-actor isolated.
final class RemoteCommandGate: Sendable {
    enum Command: Hashable, Sendable {
        case play, pause, next, previous, seek
    }

    struct Ticket: Equatable, Sendable {
        let trackID: UUID
        let revision: Int
    }

    private struct State: Sendable {
        var ticket: Ticket?
        var available: Set<Command> = []
    }

    private let state = Mutex(State())

    func update(trackID: UUID?, revision: Int = 0, available: Set<Command>) {
        let ticket = trackID.map { Ticket(trackID: $0, revision: revision) }
        state.withLock { $0 = State(ticket: ticket, available: available) }
    }

    func accept(_ command: Command) -> Ticket? {
        state.withLock { $0.available.contains(command) ? $0.ticket : nil }
    }

    func isCurrent(_ ticket: Ticket, command: Command) -> Bool {
        state.withLock { $0.ticket == ticket && $0.available.contains(command) }
    }
}
