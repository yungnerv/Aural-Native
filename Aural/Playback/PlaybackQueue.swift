import Foundation

struct PlaybackQueue {
    private(set) var original: [UUID] = []
    private(set) var order: [UUID] = []

    mutating func replace(_ ids: [UUID], current: UUID, shuffled: Bool) {
        var seen = Set<UUID>()
        original = ids.filter { seen.insert($0).inserted }
        if !seen.contains(current) { original.insert(current, at: 0) }
        setShuffle(shuffled, current: current)
    }

    mutating func setShuffle(_ enabled: Bool, current: UUID) {
        order = enabled ? [current] + original.filter { $0 != current }.shuffled() : original
    }

    mutating func remove(_ id: UUID) {
        original.removeAll { $0 == id }
        order.removeAll { $0 == id }
    }

    func adjacent(to id: UUID, direction: Int) -> UUID? {
        guard let i = order.firstIndex(of: id) else { return nil }
        let next = i + direction
        return order.indices.contains(next) ? order[next] : nil
    }
}
