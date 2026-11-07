import Foundation
import Darwin

private struct SIMDShortFilter: Sendable {
    let first: SIMD16<UInt8>
    let second: SIMD16<UInt8>
    let secondOffset: Int?
}

struct SIMDShortByteMatcher: ByteLiteralMatching {
    let pattern: Data
    let direction: SearchDirection
    private let foundation: FoundationByteMatcher
    private let filter: SIMDShortFilter?
    private var failedCandidates = 0
    private var useFoundation = false

    init(pattern: Data, direction: SearchDirection) {
        self.pattern = pattern
        self.direction = direction
        foundation = FoundationByteMatcher(pattern: pattern, direction: direction)
        if direction == .forward, (1...16).contains(pattern.count) {
            let first = pattern[pattern.startIndex]
            let secondOffset = (1..<pattern.count).last {
                pattern[pattern.startIndex + $0] != first
            }
            if pattern.count == 1 || secondOffset != nil {
                filter = SIMDShortFilter(
                    first: SIMD16<UInt8>(repeating: first),
                    second: SIMD16<UInt8>(repeating: secondOffset.map {
                        pattern[pattern.startIndex + $0]
                    } ?? first),
                    secondOffset: secondOffset)
            } else {
                filter = nil
            }
        } else {
            filter = nil
        }
    }

    mutating func find(in bytes: Data) -> Int? {
        let length = pattern.count
        // Small ranges, reverse searches, and longer or uniform needles use Foundation.
        guard !useFoundation, let filter, bytes.count >= length + 15 else {
            return foundation.find(in: bytes)
        }

        return bytes.withUnsafeBytes { haystack in
            pattern.withUnsafeBytes { needle in
                let base = haystack.baseAddress!
                let needleBase = needle.baseAddress!
                let candidateCount = haystack.count - length + 1
                var window = 0
                while window + 16 <= candidateCount {
                    let leading = haystack.loadUnaligned(fromByteOffset: window, as: SIMD16<UInt8>.self)
                    let matches: SIMDMask<SIMD16<UInt8>.MaskStorage>
                    if let secondOffset = filter.secondOffset {
                        let trailing = haystack.loadUnaligned(fromByteOffset: window + secondOffset,
                                                              as: SIMD16<UInt8>.self)
                        matches = (leading .== filter.first) .& (trailing .== filter.second)
                    } else {
                        matches = leading .== filter.first
                    }
                    // A true lane contributes bit 0 of its byte; each 64-bit word holds eight lanes.
                    let laneBytes = SIMD16<UInt8>.zero.replacing(with: SIMD16<UInt8>(repeating: 1),
                                                                 where: matches)
                    let words = unsafeBitCast(laneBytes, to: SIMD2<UInt64>.self)
                    for wordIndex in 0..<2 {
                        var bits = UInt64(littleEndian: words[wordIndex]) & 0x0101_0101_0101_0101
                        while bits != 0 {
                            let lane = wordIndex * 8 + bits.trailingZeroBitCount / 8
                            let candidate = window + lane
                            if memcmp(base.advanced(by: candidate), needleBase, length) == 0 {
                                return candidate
                            }
                            // Count across this scan; repeated misses make later blocks use Foundation.
                            failedCandidates += 1
                            if failedCandidates >= 8 {
                                useFoundation = true
                                let remaining = bytes[(bytes.startIndex + candidate + 1)..<bytes.endIndex]
                                return foundation.find(in: remaining).map { candidate + 1 + $0 }
                            }
                            bits &= bits - 1
                        }
                    }
                    window += 16
                }
                if window < candidateCount {
                    let remaining = bytes[(bytes.startIndex + window)..<bytes.endIndex]
                    return foundation.find(in: remaining).map { window + $0 }
                }
                return nil
            }
        }
    }
}
