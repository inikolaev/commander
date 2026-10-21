/// Recent wrapped-row transitions. Only byte offsets are retained.
struct ViewerRowNavigation: Sendable {
    private static let capacity = 4096
    private var startsByNext: [Int64: Int64] = [:]
    private var order: [Int64] = []

    func predecessor(endingAt next: Int64) -> Int64? { startsByNext[next] }

    mutating func record(start: Int64, next: Int64) {
        guard start >= 0, start < next else { return }
        if startsByNext.updateValue(start, forKey: next) != nil { return }
        if order.count == Self.capacity {
            for key in order.prefix(Self.capacity / 4) { startsByNext.removeValue(forKey: key) }
            order.removeFirst(Self.capacity / 4)
        }
        order.append(next)
    }

    mutating func removeAll() {
        startsByNext.removeAll()
        order.removeAll()
    }
}
