import Foundation
import Darwin

struct DarwinMemmemByteMatcher: ByteLiteralMatching {
    let pattern: Data
    let direction: SearchDirection
    private let foundation: FoundationByteMatcher

    init(pattern: Data, direction: SearchDirection) {
        self.pattern = pattern
        self.direction = direction
        foundation = FoundationByteMatcher(pattern: pattern, direction: direction)
    }

    func find(in bytes: Data) -> Int? {
        guard direction == .forward else { return foundation.find(in: bytes) }
        guard bytes.count >= pattern.count else { return nil }
        return bytes.withUnsafeBytes { haystack in
            pattern.withUnsafeBytes { needle in
                guard let found = memmem(haystack.baseAddress, haystack.count,
                                         needle.baseAddress, needle.count) else { return nil }
                return haystack.baseAddress!.distance(to: UnsafeRawPointer(found))
            }
        }
    }
}
