import Foundation

/// The system may invoke remote handlers on a background thread. This gate is
/// the only shared mutable value, and every read/write is protected by its lock.
/// Success from a handler means the request was accepted, not that audio played.
final class RemoteCommandGate: @unchecked Sendable {
    enum Command: Hashable, Sendable {
        case play, pause, next, previous, seek
    }

    private let lock = NSLock()
    private var trackID: UUID?
    private var available: Set<Command> = []

    func update(trackID: UUID?, available: Set<Command>) {
        lock.lock()
        defer { lock.unlock() }
        self.trackID = trackID
        self.available = available
    }

    func accept(_ command: Command) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return available.contains(command) ? trackID : nil
    }

    func isCurrent(_ id: UUID, command: Command) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trackID == id && available.contains(command)
    }
}
