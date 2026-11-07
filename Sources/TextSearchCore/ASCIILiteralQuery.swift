import Foundation
import Darwin

/// A byte-search shortcut for literals whose UTF-8 bytes have the same
/// positions as their source scalars. Adapters still own source validation
/// and the Unicode fallback; the scanner owns chunk overlap.
public struct ASCIILiteralQuery: Sendable {
    public let pattern: Data
    public let isCaseInsensitive: Bool

    public init?(query: TextSearchQuery, maximumLength: Int) {
        guard !query.wholeWord else { return nil }
        let bytes = Array(query.text.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLength,
              bytes.allSatisfy({ $0 < 0x80 && $0 != 10 && $0 != 13 }) else { return nil }
        isCaseInsensitive = !query.caseSensitive
        pattern = Data(isCaseInsensitive ? bytes.map(Self.lowercase) : bytes)
    }

    /// Return nil when ASCII-only traversal encounters Unicode text. The
    /// caller must restart with the scalar matcher: full Unicode folding can
    /// turn a non-ASCII source scalar into ASCII query characters.
    public func preparedBlock(_ bytes: Data, requireASCII: Bool) -> Data? {
        if !requireASCII && !isCaseInsensitive { return bytes }
        if !isCaseInsensitive {
            let isASCII = bytes.withUnsafeBytes { raw in
                let vectorEnd = raw.count - raw.count % 16
                var index = 0
                while index < vectorEnd {
                    let block = raw.loadUnaligned(fromByteOffset: index, as: SIMD16<UInt8>.self)
                    if Self.containsNonASCII(block) { return false }
                    index += 16
                }
                while index < raw.count {
                    if raw[index] >= 0x80 { return false }
                    index += 1
                }
                return true
            }
            return isASCII ? bytes : nil
        }
        var folded = Data(count: bytes.count)
        let isASCII = bytes.withUnsafeBytes { source in
            folded.withUnsafeMutableBytes { destination -> Bool in
                let upperA = SIMD16<UInt8>(repeating: 65)
                let upperZ = SIMD16<UInt8>(repeating: 90)
                let lowercaseBit = SIMD16<UInt8>(repeating: 32)
                let vectorEnd = source.count - source.count % 16
                var index = 0
                while index < vectorEnd {
                    let block = source.loadUnaligned(fromByteOffset: index, as: SIMD16<UInt8>.self)
                    if Self.containsNonASCII(block) { return false }
                    let uppercase = (block .>= upperA) .& (block .<= upperZ)
                    let lowered = block.replacing(with: block | lowercaseBit, where: uppercase)
                    destination.storeBytes(of: lowered, toByteOffset: index, as: SIMD16<UInt8>.self)
                    index += 16
                }
                while index < source.count {
                    let byte = source[index]
                    if byte >= 0x80 { return false }
                    destination[index] = Self.lowercase(byte)
                    index += 1
                }
                return true
            }
        }
        return isASCII ? folded : nil
    }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    @inline(__always)
    private static func containsNonASCII(_ block: SIMD16<UInt8>) -> Bool {
        // Both vectors are 16 bytes; masking both 64-bit words tests each byte's high bit.
        let words = unsafeBitCast(block, to: SIMD2<UInt64>.self)
        return ((words[0] | words[1]) & 0x8080_8080_8080_8080) != 0
    }
}

public enum ASCIILiteralScanResult<Offset: FixedWidthInteger & Sendable>: Sendable {
    case advance
    case match(TextMatch<Offset>)
    case requiresUnicode
}

/// Internal benchmark selector. The ordinary scanner initializer always uses
/// Foundation; opt-in strategies are exposed only to benchmark clients.
@_spi(Benchmark)
public enum ASCIILiteralMatcher: Sendable {
    case foundation
    case darwinMemmem
}

/// The byte matcher shared by viewer and editor. Call with contiguous blocks
/// in traversal order; source reads, offset validation, and fallback belong to
/// the adapter. Only a query-length boundary is copied between blocks. Stop
/// calling `consume` after `.match` or `.requiresUnicode`.
public struct ASCIILiteralScanner<Offset: FixedWidthInteger & Sendable> {
    private let query: ASCIILiteralQuery
    private let direction: SearchDirection
    private let matcher: ASCIILiteralMatcher
    private var carry = Data()

    public init(query: ASCIILiteralQuery, direction: SearchDirection) {
        self.init(query: query, direction: direction, matcher: .foundation)
    }

    @_spi(Benchmark)
    public init(query: ASCIILiteralQuery, direction: SearchDirection, matcher: ASCIILiteralMatcher) {
        self.query = query
        self.direction = direction
        self.matcher = matcher
    }

    public mutating func consume(_ bytes: Data, startingAt start: Offset,
                                 requireASCII: Bool) -> ASCIILiteralScanResult<Offset> {
        guard let block = query.preparedBlock(bytes, requireASCII: requireASCII) else {
            return .requiresUnicode
        }
        let overlap = query.pattern.count - 1
        if direction == .forward {
            var boundary = carry
            boundary.append(block.prefix(overlap))
            if let offset = findForward(boundary) {
                return match(start - Offset(carry.count) + Offset(offset))
            }
            if let offset = findForward(block) {
                return match(start + Offset(offset))
            }
            if block.count >= overlap {
                carry = Data(block.suffix(overlap))
            } else {
                carry.append(block)
                carry = Data(carry.suffix(overlap))
            }
        } else {
            let suffix = block.suffix(overlap)
            var boundary = Data(suffix)
            boundary.append(carry)
            if let offset = Self.foundationBackward(boundary, query.pattern) {
                return match(start + Offset(block.count - suffix.count)
                             + Offset(offset))
            }
            if let offset = Self.foundationBackward(block, query.pattern) {
                return match(start + Offset(offset))
            }
            if block.count >= overlap {
                carry = Data(block.prefix(overlap))
            } else {
                var next = Data(block)
                next.append(carry)
                carry = Data(next.prefix(overlap))
            }
        }
        return .advance
    }

    private func match(_ start: Offset) -> ASCIILiteralScanResult<Offset> {
        .match(TextMatch(lowerBound: start,
                         upperBound: start + Offset(query.pattern.count))!)
    }

    private func findForward(_ bytes: Data) -> Int? {
        switch matcher {
        case .foundation: Self.foundationForward(bytes, query.pattern)
        case .darwinMemmem: Self.darwinMemmemForward(bytes, query.pattern)
        }
    }

    private static func foundationForward(_ bytes: Data, _ pattern: Data) -> Int? {
        bytes.range(of: pattern).map { $0.lowerBound - bytes.startIndex }
    }

    private static func foundationBackward(_ bytes: Data, _ pattern: Data) -> Int? {
        bytes.range(of: pattern, options: .backwards).map { $0.lowerBound - bytes.startIndex }
    }

    private static func darwinMemmemForward(_ bytes: Data, _ pattern: Data) -> Int? {
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
