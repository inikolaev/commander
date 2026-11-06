import Foundation
import TextSearchCore

/// A match in original file bytes. Offsets are half-open and remain valid in
/// both text and hex presentation, subject to `validate` before reveal.
public struct ViewerSearchHit: Sendable, Equatable {
    public let lowerBound: Int64
    public let upperBound: Int64
    public let revision: UInt64?
    public let sourceSize: Int64?

    public init(lowerBound: Int64, upperBound: Int64, revision: UInt64?, sourceSize: Int64?) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.revision = revision
        self.sourceSize = sourceSize
    }
}

public enum ViewerSearchResult: Sendable, Equatable {
    case found(ViewerSearchHit)
    case exhausted
    case cancelled
    case sourceChanged
}

/// Scans a retained content source without acquiring the viewer page gate.
/// One scan holds one block and one matcher state, regardless of file length.
public struct ViewerSearchSource: Sendable {
    public let source: any FileContentSource
    public let chunkSize: Int

    public init(source: any FileContentSource, chunkSize: Int = 65_536) {
        precondition(chunkSize > 0)
        self.source = source
        self.chunkSize = chunkSize
    }

    /// `fromByteOffset` is inclusive, based on the match's first byte in both
    /// directions. A caller can resume forward at a hit's lowerBound + 1 and
    /// backward at lowerBound - 1 to include overlapping matches.
    public func search(
        _ query: TextSearchQuery,
        direction: SearchDirection,
        fromByteOffset: Int64,
        exclusiveStartLimit: Int64? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) async throws -> ViewerSearchResult {
        guard !query.isEmpty else { return .exhausted }
        guard fromByteOffset >= 0 else { throw ContentSourceError.invalidRange }
        if let exclusiveStartLimit, exclusiveStartLimit < 0 { throw ContentSourceError.invalidRange }
        if let limit = exclusiveStartLimit,
           direction == .forward ? fromByteOffset >= limit : fromByteOffset <= limit { return .exhausted }
        if cancelled(isCancelled) { return .cancelled }
        do {
            let initial = try await source.metadata()
            guard initial.size == nil || initial.size! >= 0 else { return .sourceChanged }
            if let ascii = ASCIILiteralQuery(query: query, maximumLength: chunkSize),
               let result = try await searchASCII(ascii,
                                                  direction: direction, anchor: fromByteOffset,
                                                  exclusiveStartLimit: exclusiveStartLimit,
                                                  initial: initial, isCancelled: isCancelled) {
                return result
            }
            guard var machine = LiteralSearchMachine<Int64>(query: query, direction: direction) else {
                return .exhausted
            }
            var resolvedSize: Int64?
            if direction == .forward {
                // Four bytes cover a preceding UTF-8 scalar or CRLF boundary.
                // Matches before the requested anchor are discarded below.
                var offset: Int64 = max(0, fromByteOffset - 4)
                if let size = initial.size, offset >= size { return .exhausted }
                var remainder = [UInt8]()
                var remainderOffset = offset
                var reachedLimit = false
                let scalarCount = Int64(clamping: query.maximumMatchSourceScalars)
                let (extent, overflow) = scalarCount.multipliedReportingOverflow(by: 4)
                let stopAfter = exclusiveStartLimit.map { limit -> Int64 in
                    let (end, added) = limit.addingReportingOverflow(overflow ? Int64.max : extent)
                    return added ? Int64.max : end
                }
                while true {
                    if cancelled(isCancelled) { return .cancelled }
                    if let size = initial.size, offset >= size { break }
                    let count = initial.size.map { min(chunkSize, Int(min(Int64(chunkSize), $0 - offset))) } ?? chunkSize
                    let data = try await source.read(at: offset, count: count)
                    if data.count > count { return .sourceChanged }
                    if let size = initial.size, data.isEmpty && offset < size { return .sourceChanged }
                    if !(try await unchanged(initial)) { return .sourceChanged }
                    if remainder.isEmpty { remainderOffset = offset }
                    remainder.append(contentsOf: data)
                    let eof = data.isEmpty || (initial.size.map { offset + Int64(data.count) == $0 } ?? false)
                    let decoded = Self.decode(remainder, at: remainderOffset, final: eof)
                    for item in decoded.inputs {
                        // Consume the boundary scalar to settle a pending whole-word
                        // candidate whose start is still inside the interval.
                        if let stopAfter, item.start > stopAfter { reachedLimit = true }
                        switch machine.consume(item.input, isCancelled: { cancelled(isCancelled) }) {
                        case .cancelled: return .cancelled
                        case .advance: break
                        case .match(let span):
                            if span.lowerBound >= fromByteOffset &&
                               (exclusiveStartLimit == nil || span.lowerBound < exclusiveStartLimit!) {
                                if !(try await unchanged(initial)) { return .sourceChanged }
                                return .found(hit(span, initial))
                            }
                        }
                        if reachedLimit { break }
                    }
                    remainder = Array(remainder.dropFirst(decoded.consumed))
                    remainderOffset += Int64(decoded.consumed)
                    offset += Int64(data.count)
                    if eof || reachedLimit { break }
                }
            } else {
                // Only unknown-length sources need full preparation for reverse traversal.
                let end: Int64
                if let size = initial.size { end = size }
                else { end = try await source.length() }
                resolvedSize = end
                if !(try await unchanged(initial, resolvedSize: end)) { return .sourceChanged }
                // Each matching source scalar can occupy four UTF-8 bytes.
                // Keep one trailing scalar for whole-word validation and
                // saturate for huge queries.
                let scalarCount = Int64(clamping: query.maximumMatchSourceScalars)
                let (extent, multiplied) = scalarCount.multipliedReportingOverflow(by: 4)
                let (limit, added) = fromByteOffset.addingReportingOverflow((multiplied ? Int64.max - 4 : extent) + 4)
                var blockEnd = min(end, added ? Int64.max : limit)
                var reachedLimit = false
                while blockEnd > 0 {
                    if cancelled(isCancelled) { return .cancelled }
                    let blockStart = max(0, blockEnd - Int64(chunkSize))
                    let readStart = max(0, blockStart - 3)
                    let readEnd = min(end, blockEnd + 4) // UTF-8 tail and CRLF ownership
                    let count = Int(readEnd - readStart)
                    let data = try await source.read(at: readStart, count: count)
                    if data.count != count { return .sourceChanged }
                    if !(try await unchanged(initial, resolvedSize: end)) { return .sourceChanged }
                    let decoded = Self.decode(Array(data), at: readStart, final: readEnd == end)
                    for item in decoded.inputs.reversed() where item.start >= blockStart && item.start < blockEnd {
                        if let limit = exclusiveStartLimit, item.start <= limit { reachedLimit = true }
                        switch machine.consume(item.input, isCancelled: { cancelled(isCancelled) }) {
                        case .cancelled: return .cancelled
                        case .advance: break
                        case .match(let span):
                            if span.lowerBound <= fromByteOffset &&
                               (exclusiveStartLimit == nil || span.lowerBound > exclusiveStartLimit!) {
                                if !(try await unchanged(initial, resolvedSize: end)) { return .sourceChanged }
                                return .found(hit(span, initial, resolvedSize: end))
                            }
                        }
                        if reachedLimit { break }
                    }
                    if reachedLimit { break }
                    blockEnd = blockStart
                }
            }
            switch machine.finish(isCancelled: { cancelled(isCancelled) }) {
            case .cancelled: return .cancelled
            case .match(let span):
                let eligible = direction == .forward
                    ? span.lowerBound >= fromByteOffset && (exclusiveStartLimit == nil || span.lowerBound < exclusiveStartLimit!)
                    : span.lowerBound <= fromByteOffset && (exclusiveStartLimit == nil || span.lowerBound > exclusiveStartLimit!)
                if eligible {
                    if !(try await unchanged(initial, resolvedSize: resolvedSize)) { return .sourceChanged }
                    return .found(hit(span, initial, resolvedSize: resolvedSize))
                }
            case .advance: break
            }
            if !(try await unchanged(initial, resolvedSize: resolvedSize)) { return .sourceChanged }
            return .exhausted
        } catch is CancellationError {
            return .cancelled
        }
    }

    /// Rechecks source identity and the candidate bytes before presentation.
    /// The byte comparison also supports sources that expose no revision.
    public func validate(_ hit: ViewerSearchHit, query: TextSearchQuery) async throws -> Bool {
        let metadata = try await source.metadata()
        if let revision = hit.revision, metadata.revision != revision { return false }
        if let size = hit.sourceSize {
            let currentSize: Int64
            if let known = metadata.size { currentSize = known }
            else { currentSize = try await source.length() }
            if currentSize != size { return false }
        }
        guard hit.lowerBound >= 0, hit.upperBound > hit.lowerBound else { return false }
        let result = try await search(query, direction: .forward, fromByteOffset: hit.lowerBound,
                                      exclusiveStartLimit: hit.lowerBound + 1)
        if case .found(let current) = result {
            guard current.lowerBound == hit.lowerBound && current.upperBound == hit.upperBound,
                  current.revision == hit.revision else { return false }
            let final = try await source.metadata()
            if let revision = hit.revision, final.revision != revision { return false }
            if let size = hit.sourceSize {
                let finalSize: Int64
                if let known = final.size { finalSize = known }
                else { finalSize = try await source.length() }
                if finalSize != size { return false }
            }
            return true
        }
        return false
    }

    private func unchanged(_ initial: ContentMetadata, resolvedSize: Int64? = nil) async throws -> Bool {
        let current = try await source.metadata()
        if let revision = initial.revision, current.revision != revision { return false }
        if let size = initial.size, current.size != size { return false }
        if let resolvedSize {
            let size: Int64
            if let known = current.size { size = known }
            else { size = try await source.length() }
            if size != resolvedSize { return false }
        }
        return true
    }

    private func hit(_ match: TextMatch<Int64>, _ metadata: ContentMetadata, resolvedSize: Int64? = nil) -> ViewerSearchHit {
        ViewerSearchHit(lowerBound: match.lowerBound, upperBound: match.upperBound,
                        revision: metadata.revision, sourceSize: metadata.size ?? resolvedSize)
    }

    private func cancelled(_ external: @Sendable () -> Bool) -> Bool {
        Task.isCancelled || external()
    }

    /// Nil requests a Unicode fallback after encountering non-ASCII source
    /// bytes in an insensitive search. Completed results retain the same
    /// metadata and cancellation checks as the scalar scan.
    private func searchASCII(
        _ ascii: ASCIILiteralQuery,
        direction: SearchDirection,
        anchor: Int64,
        exclusiveStartLimit: Int64?,
        initial: ContentMetadata,
        isCancelled: @Sendable () -> Bool
    ) async throws -> ViewerSearchResult? {
        let pattern = ascii.pattern
        let overlap = pattern.count - 1
        var scanner = ASCIILiteralScanner<Int64>(query: ascii, direction: direction)
        if direction == .forward {
            var offset = anchor
            let stopAfter = exclusiveStartLimit.map { limit -> Int64 in
                let (end, overflow) = limit.addingReportingOverflow(Int64(overlap))
                return overflow ? Int64.max : end
            }
            while true {
                if cancelled(isCancelled) { return .cancelled }
                let end = min(initial.size ?? Int64.max, stopAfter ?? Int64.max)
                guard offset < end else { break }
                let count = Int(min(Int64(chunkSize), end - offset))
                let raw = try await source.read(at: offset, count: count)
                if raw.count > count || (raw.isEmpty && initial.size.map({ offset < $0 }) == true) {
                    return .sourceChanged
                }
                if !(try await unchanged(initial)) { return .sourceChanged }
                switch scanner.consume(raw, startingAt: offset, requireASCII: false) {
                case .requiresUnicode: return nil
                case .advance: break
                case .match(let match):
                    let start = match.lowerBound
                    if exclusiveStartLimit.map({ start >= $0 }) == true { break }
                    if !(try await unchanged(initial)) { return .sourceChanged }
                    return .found(ViewerSearchHit(lowerBound: start,
                                                  upperBound: match.upperBound,
                                                  revision: initial.revision, sourceSize: initial.size))
                }
                offset += Int64(raw.count)
                if raw.isEmpty { break }
            }
            if !(try await unchanged(initial)) { return .sourceChanged }
            return .exhausted
        }

        let end: Int64
        if let known = initial.size { end = known }
        else { end = try await source.length() }
        if !(try await unchanged(initial, resolvedSize: end)) { return .sourceChanged }
        let (requestedEnd, overflow) = anchor.addingReportingOverflow(Int64(pattern.count))
        var blockEnd = min(end, overflow ? Int64.max : requestedEnd)
        let lowerBound = exclusiveStartLimit.map { $0 + 1 } ?? 0
        while blockEnd > lowerBound {
            if cancelled(isCancelled) { return .cancelled }
            let blockStart = max(lowerBound, blockEnd - Int64(chunkSize))
            let count = Int(blockEnd - blockStart)
            let raw = try await source.read(at: blockStart, count: count)
            if raw.count != count { return .sourceChanged }
            if !(try await unchanged(initial, resolvedSize: end)) { return .sourceChanged }
            switch scanner.consume(raw, startingAt: blockStart, requireASCII: false) {
            case .requiresUnicode: return nil
            case .advance: break
            case .match(let match):
                let start = match.lowerBound
                if !(try await unchanged(initial, resolvedSize: end)) { return .sourceChanged }
                return .found(ViewerSearchHit(lowerBound: start,
                                              upperBound: match.upperBound,
                                              revision: initial.revision,
                                              sourceSize: initial.size ?? end))
            }
            blockEnd = blockStart
        }
        if !(try await unchanged(initial, resolvedSize: end)) { return .sourceChanged }
        return .exhausted
    }

    private struct LocatedInput {
        let input: TextSearchInput<Int64>
        let start: Int64
    }

    private static func decode(_ bytes: [UInt8], at base: Int64, final: Bool) -> (inputs: [LocatedInput], consumed: Int) {
        var result = [LocatedInput]()
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let width: Int
            let minimum: UInt32
            if first < 0x80 { width = 1; minimum = 0 }
            else if (0xC2...0xDF).contains(first) { width = 2; minimum = 0x80 }
            else if (0xE0...0xEF).contains(first) { width = 3; minimum = 0x800 }
            else if (0xF0...0xF4).contains(first) { width = 4; minimum = 0x10000 }
            else { result.append(LocatedInput(input: .barrier, start: base + Int64(index))); index += 1; continue }
            if index + width > bytes.count {
                if !final { break }
                result.append(LocatedInput(input: .barrier, start: base + Int64(index))); index += 1; continue
            }
            var value = UInt32(first & (width == 1 ? 0x7F : 0x7F >> width))
            var valid = true
            if width > 1 {
                for continuation in bytes[(index + 1)..<(index + width)] {
                    if continuation & 0xC0 != 0x80 { valid = false; break }
                    value = (value << 6) | UInt32(continuation & 0x3F)
                }
            }
            guard valid, value >= minimum, !(0xD800...0xDFFF).contains(value), value <= 0x10FFFF,
                  let scalar = Unicode.Scalar(value) else {
                result.append(LocatedInput(input: .barrier, start: base + Int64(index))); index += 1; continue
            }
            var consumed = width
            var normalized = scalar
            if value == 13, index + width == bytes.count, !final { break }
            if value == 13, index + 1 < bytes.count, bytes[index + 1] == 10 {
                normalized = "\n".unicodeScalars.first!
                consumed = 2
            }
            if let input = TextSearchScalar(value: normalized, lowerBound: base + Int64(index),
                                            upperBound: base + Int64(index + consumed)) {
                result.append(LocatedInput(input: .scalar(input), start: base + Int64(index)))
            }
            index += consumed
        }
        return (result, index)
    }
}
