import Foundation

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
                for byte in raw.bindMemory(to: UInt8.self) {
                    if byte >= 0x80 { return false }
                }
                return true
            }
            return isASCII ? bytes : nil
        }
        var folded = Data(count: bytes.count)
        let isASCII = bytes.withUnsafeBytes { source in
            folded.withUnsafeMutableBytes { destination -> Bool in
                let source = source.bindMemory(to: UInt8.self)
                let destination = destination.bindMemory(to: UInt8.self)
                for index in source.indices {
                    let byte = source[index]
                    if byte >= 0x80 { return false }
                    destination[index] = Self.lowercase(byte)
                }
                return true
            }
        }
        return isASCII ? folded : nil
    }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}

public enum ASCIILiteralScanResult<Offset: FixedWidthInteger & Sendable>: Sendable {
    case advance
    case match(TextMatch<Offset>)
    case requiresUnicode
}

/// The byte matcher shared by viewer and editor. Call with contiguous blocks
/// in traversal order; source reads, offset validation, and fallback belong to
/// the adapter. Only a query-length boundary is copied between blocks. Stop
/// calling `consume` after `.match` or `.requiresUnicode`.
public struct ASCIILiteralScanner<Offset: FixedWidthInteger & Sendable> {
    private let query: ASCIILiteralQuery
    private let direction: SearchDirection
    private var carry = Data()

    public init(query: ASCIILiteralQuery, direction: SearchDirection) {
        self.query = query
        self.direction = direction
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
            if let range = boundary.range(of: query.pattern) {
                return match(start - Offset(carry.count) + Offset(range.lowerBound - boundary.startIndex))
            }
            if let range = block.range(of: query.pattern) {
                return match(start + Offset(range.lowerBound - block.startIndex))
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
            if let range = boundary.range(of: query.pattern, options: .backwards) {
                return match(start + Offset(block.count - suffix.count)
                             + Offset(range.lowerBound - boundary.startIndex))
            }
            if let range = block.range(of: query.pattern, options: .backwards) {
                return match(start + Offset(range.lowerBound - block.startIndex))
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
}
