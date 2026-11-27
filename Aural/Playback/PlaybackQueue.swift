import Foundation

struct PlaybackQueue: Sendable {
    private(set) var original: [UUID] = []
    private(set) var order: [UUID] = []
    private var positions: [UUID: Int] = [:]

    private mutating func rebuildPositions() {
        positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
    }

    mutating func replace(_ ids: [UUID], current: UUID, shuffled: Bool) {
        var seen = Set<UUID>()
        original = ids.filter { seen.insert($0).inserted }
        if !seen.contains(current) { original.insert(current, at: 0) }
        setShuffle(shuffled, current: current)
    }

    mutating func setShuffle(_ enabled: Bool, current: UUID) {
        order = enabled ? [current] + original.filter { $0 != current }.shuffled() : original
        rebuildPositions()
    }

    mutating func remove(_ id: UUID) {
        original.removeAll { $0 == id }
        order.removeAll { $0 == id }
        rebuildPositions()
    }

    mutating func retain(_ allowed: Set<UUID>) {
        original = original.filter { allowed.contains($0) }
        order = order.filter { allowed.contains($0) }
        rebuildPositions()
    }

    func adjacent(to id: UUID, direction: Int) -> UUID? {
        guard let i = positions[id] else { return nil }
        let (next, overflow) = i.addingReportingOverflow(direction)
        guard !overflow else { return nil }
        return order.indices.contains(next) ? order[next] : nil
    }
}
