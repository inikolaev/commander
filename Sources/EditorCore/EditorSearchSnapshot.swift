import Foundation
@_spi(Benchmark) import TextSearchCore
internal import TextBuffer

/// A hit in editor UTF-16 coordinates. Use `exactRange` to continue a search;
/// use `selectionRange` when moving a caret or painting the active result.
public struct EditorSearchHit: Sendable, Equatable {
    public let exactRange: NSRange
    public let selectionRange: NSRange
    public let contentVersion: Int

    public func isCurrent(contentVersion: Int) -> Bool { self.contentVersion == contentVersion }
}

public enum EditorSearchResult: Sendable, Equatable {
    case found(EditorSearchHit)
    case exhausted
    case cancelled
}

/// Immutable copy-on-write rope captured from a live editor on the main actor.
/// The storage library stays behind this project-owned boundary.
public struct EditorSearchSnapshot: Sendable {
    private let buffer: SendableRopeBuffer
    public let contentVersion: Int
    public let length: Int

    internal init(buffer: SendableRopeBuffer, contentVersion: Int) {
        self.buffer = buffer
        self.contentVersion = contentVersion
        self.length = buffer.range.length
    }

    /// A search-free read control for performance measurements. It follows the
    /// ASCII search path's rope slices and UTF-8 materialization, omitting only
    /// query preparation and matching. The checksum samples block boundaries
    /// so it does not add a second byte-by-byte pass.
    @_spi(Benchmark)
    @inline(never)
    public func scanBlocks(direction: SearchDirection, chunkSize: Int = 65_536) -> (units: Int, checksum: UInt64) {
        precondition(chunkSize > 0)
        var cursor = direction == .forward ? 0 : length
        var units = 0
        var checksum: UInt64 = 0xcbf29ce484222325
        while direction == .forward ? cursor < length : cursor > 0 {
            let start: Int
            let end: Int
            if direction == .forward {
                start = cursor
                end = forwardChunkEnd(from: cursor, target: cursor + min(chunkSize, length - cursor))
            } else {
                start = reverseChunkStart(to: cursor, target: cursor - min(chunkSize, cursor))
                end = cursor
            }
            let bytes = Data(buffer.rope.content(in: start..<end).utf8)
            if let first = bytes.first, let last = bytes.last {
                checksum = (checksum &* 0x100000001b3) ^ UInt64(first)
                    ^ (UInt64(last) << 8) ^ UInt64(bytes.count)
            }
            units += end - start
            cursor = direction == .forward ? end : start
        }
        return (units, checksum)
    }

    /// The anchor is an inclusive match-start offset. Navigation advances it
    /// by one UTF-16 unit to find overlapping matches. There is no wrap here.
    public func search(
        _ query: TextSearchQuery,
        direction: SearchDirection,
        fromUTF16Offset anchor: Int,
        exclusiveStartLimit: Int? = nil,
        chunkSize: Int = 65_536,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> EditorSearchResult {
        searchImpl(query, direction: direction, fromUTF16Offset: anchor,
                   exclusiveStartLimit: exclusiveStartLimit, chunkSize: chunkSize,
                   matcher: .foundation, isCancelled: isCancelled)
    }

    @_spi(Benchmark)
    public func search(
        _ query: TextSearchQuery,
        direction: SearchDirection,
        fromUTF16Offset anchor: Int,
        exclusiveStartLimit: Int? = nil,
        chunkSize: Int = 65_536,
        matcher: ASCIILiteralMatcher,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> EditorSearchResult {
        searchImpl(query, direction: direction, fromUTF16Offset: anchor,
                   exclusiveStartLimit: exclusiveStartLimit, chunkSize: chunkSize,
                   matcher: matcher, isCancelled: isCancelled)
    }

    private func searchImpl(
        _ query: TextSearchQuery,
        direction: SearchDirection,
        fromUTF16Offset anchor: Int,
        exclusiveStartLimit: Int?,
        chunkSize: Int,
        matcher: ASCIILiteralMatcher,
        isCancelled: @Sendable () -> Bool
    ) -> EditorSearchResult {
        precondition(chunkSize > 0)
        guard !query.isEmpty else { return .exhausted }
        if Task.isCancelled || isCancelled() { return .cancelled }
        if let ascii = ASCIILiteralQuery(query: query, maximumLength: chunkSize),
           let result = searchASCII(ascii, direction: direction, anchor: anchor,
                                    exclusiveStartLimit: exclusiveStartLimit,
                                    chunkSize: chunkSize, matcher: matcher,
                                    isCancelled: isCancelled) {
            return result
        }
        guard var machine = LiteralSearchMachine<Int>(query: query, direction: direction) else {
            return .exhausted
        }
        // A forward scan needs the scalar immediately before its first
        // candidate for whole-word matching. A reverse scan needs enough
        // source to finish a match starting at the anchor, plus its right
        // word boundary. A source scalar occupies at most two UTF-16 units.
        let context = Self.matchContextLength(query, length: length)
        let clampedAnchor = min(length, max(0, anchor))
        let cursorStart: Int
        if direction == .forward {
            let aligned = scalarBoundary(atOrAfter: clampedAnchor)
            cursorStart = aligned == 0 ? 0
                : reverseChunkStart(to: aligned, target: max(0, aligned - 2))
        } else {
            let rightEdge = clampedAnchor > length - context ? length : clampedAnchor + context
            cursorStart = scalarBoundary(atOrAfter: rightEdge)
        }
        var cursor = cursorStart
        // Forward matches may finish beyond the last allowed start. A source
        // scalar occupies at most two UTF-16 units. The shared core provides
        // the maximum source-scalar count for this query.
        let forwardStop = exclusiveStartLimit.map { limit in
            return limit > length - context ? length : max(0, limit + context)
        }

        while direction == .forward ? cursor < length : cursor > 0 {
            if Task.isCancelled || isCancelled() { return .cancelled }
            let start: Int
            let end: Int
            if direction == .forward {
                start = cursor
                end = forwardChunkEnd(from: cursor, target: cursor + min(chunkSize, length - cursor))
            } else {
                start = reverseChunkStart(to: cursor, target: cursor - min(chunkSize, cursor))
                end = cursor
            }
            // The rope's raw slice takes exact UTF-16 offsets. Align only a
            // split surrogate pair; Swift grapheme segmentation is done later
            // on a context window when a hit needs a selection range.
            let text = buffer.rope.content(in: start..<end)
            precondition(text.utf16.count == end - start && end > start)
            cursor = direction == .forward ? end : start
            guard let scalars = Self.locateScalars(text, at: start, isCancelled: isCancelled) else {
                return .cancelled
            }
            let traversal = direction == .forward ? scalars : Array(scalars.reversed())
            for located in traversal {
                if direction == .forward, let forwardStop,
                   located.scalarRange.location >= forwardStop { return .exhausted }
                // The first scalar at or across the backward limit supplies
                // the left word boundary for a hit whose start is above it.
                let completesBackwardBoundary = direction == .backward
                    && exclusiveStartLimit.map { located.scalarRange.location <= $0 } == true
                let input = TextSearchScalar<Int>(
                    value: located.value,
                    lowerBound: located.scalarRange.location,
                    upperBound: NSMaxRange(located.scalarRange)
                )!
                switch machine.consume(.scalar(input), isCancelled: { Task.isCancelled || isCancelled() }) {
                case .cancelled: return .cancelled
                case .advance: break
                case .match(let match):
                    if eligible(match, direction: direction, anchor: anchor,
                                exclusiveStartLimit: exclusiveStartLimit) {
                        return makeHit(match, isCancelled: isCancelled)
                    }
                }
                if completesBackwardBoundary { return .exhausted }
            }
        }
        switch machine.finish(isCancelled: { Task.isCancelled || isCancelled() }) {
        case .cancelled: return .cancelled
        case .advance: return .exhausted
        case .match(let match):
            return eligible(match, direction: direction, anchor: anchor,
                            exclusiveStartLimit: exclusiveStartLimit)
                ? makeHit(match, isCancelled: isCancelled) : .exhausted
        }
    }

    /// ASCII source blocks have identical UTF-8 and UTF-16 positions. If a
    /// block contains Unicode, restart with the scalar scanner because full
    /// case folding can turn that source text into an ASCII query match.
    private func searchASCII(
        _ ascii: ASCIILiteralQuery,
        direction: SearchDirection,
        anchor: Int,
        exclusiveStartLimit: Int?,
        chunkSize: Int,
        matcher: ASCIILiteralMatcher,
        isCancelled: @Sendable () -> Bool
    ) -> EditorSearchResult? {
        let pattern = ascii.pattern
        let overlap = pattern.count - 1
        var scanner = ASCIILiteralScanner<Int>(query: ascii, direction: direction, matcher: matcher)
        if direction == .forward {
            if let exclusiveStartLimit, anchor >= exclusiveStartLimit { return .exhausted }
            var cursor = scalarBoundary(atOrAfter: min(length, max(0, anchor)))
            let stop: Int
            if let limit = exclusiveStartLimit {
                stop = limit > length - min(length, overlap) ? length : min(length, max(0, limit + overlap))
            } else { stop = length }
            while cursor < stop {
                if Task.isCancelled || isCancelled() { return .cancelled }
                let end = forwardChunkEnd(from: cursor, target: cursor + min(chunkSize, stop - cursor))
                let text = buffer.rope.content(in: cursor..<end)
                switch scanner.consume(Data(text.utf8), startingAt: cursor, requireASCII: true) {
                case .requiresUnicode: return nil
                case .advance: break
                case .match(let match):
                    if exclusiveStartLimit.map({ match.lowerBound >= $0 }) == true { return .exhausted }
                    return makeHit(match, isCancelled: isCancelled)
                }
                cursor = end
            }
            return .exhausted
        }

        if anchor < 0 { return .exhausted }
        if let exclusiveStartLimit, anchor <= exclusiveStartLimit { return .exhausted }
        let clampedAnchor = min(length, anchor)
        let rightEdge = clampedAnchor > length - min(length, pattern.count)
            ? length : clampedAnchor + pattern.count
        var cursor = scalarBoundary(atOrAfter: rightEdge)
        let lowerBound = exclusiveStartLimit.map { max(0, $0 + 1) } ?? 0
        while cursor > lowerBound {
            if Task.isCancelled || isCancelled() { return .cancelled }
            let start = reverseChunkStart(to: cursor, target: max(lowerBound, cursor - min(chunkSize, cursor)))
            let text = buffer.rope.content(in: start..<cursor)
            switch scanner.consume(Data(text.utf8), startingAt: start, requireASCII: true) {
            case .requiresUnicode: return nil
            case .advance: break
            case .match(let match):
                return makeHit(match, isCancelled: isCancelled)
            }
            cursor = start
        }
        return .exhausted
    }

    private static func matchContextLength(_ query: TextSearchQuery, length: Int) -> Int {
        let units = query.maximumMatchSourceScalars.multipliedReportingOverflow(by: 2)
        if units.overflow || units.partialValue >= length - min(length, 2) { return length }
        return min(length, units.partialValue + 2)
    }

    /// TextRope's String slice rounds an end between surrogate halves down
    /// to the preceding scalar boundary. A one-unit slice ending there is
    /// empty. Probe only that unit: a larger slice starting at an arbitrary
    /// offset can expand across a surrogate and corrupt its offset mapping.
    private func scalarBoundary(atOrAfter offset: Int) -> Int {
        if offset <= 0 { return 0 }
        if offset >= length { return length }
        return buffer.rope.content(in: offset - 1..<offset).isEmpty ? offset + 1 : offset
    }

    private func scalarBoundary(atOrBefore offset: Int) -> Int {
        if offset <= 0 { return 0 }
        if offset >= length { return length }
        return buffer.rope.content(in: offset - 1..<offset).isEmpty ? offset - 1 : offset
    }

    private func eligible(_ match: TextMatch<Int>, direction: SearchDirection, anchor: Int,
                          exclusiveStartLimit: Int?) -> Bool {
        if let exclusiveStartLimit {
            if direction == .forward && match.lowerBound >= exclusiveStartLimit { return false }
            if direction == .backward && match.lowerBound <= exclusiveStartLimit { return false }
        }
        return direction == .forward ? match.lowerBound >= anchor : match.lowerBound <= anchor
    }

    private func makeHit(_ match: TextMatch<Int>, isCancelled: @Sendable () -> Bool) -> EditorSearchResult {
        if Task.isCancelled || isCancelled() { return .cancelled }
        guard let first = swiftGrapheme(containing: match.lowerBound, alignedAnchor: match.lowerBound,
                                        isCancelled: isCancelled) else { return .cancelled }
        guard let last = swiftGrapheme(containing: match.upperBound - 1, alignedAnchor: match.upperBound,
                                       isCancelled: isCancelled) else { return .cancelled }
        if Task.isCancelled || isCancelled() { return .cancelled }
        return .found(EditorSearchHit(
            exactRange: NSRange(location: match.lowerBound, length: match.upperBound - match.lowerBound),
            selectionRange: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
            contentVersion: contentVersion
        ))
    }

    /// Round the requested chunk end to a scalar boundary. The starting edge
    /// is already aligned by the preceding chunk or search anchor.
    private func forwardChunkEnd(from start: Int, target: Int) -> Int {
        scalarBoundary(atOrAfter: target)
    }

    /// Round the requested chunk start down to a scalar boundary.
    private func reverseChunkStart(to end: Int, target: Int) -> Int {
        scalarBoundary(atOrBefore: target)
    }

    /// Swift `Character` and Foundation composed ranges disagree for some
    /// scripts (for example U+0600 before a digit). Expand a raw, scalar-
    /// aligned window until the target's Swift grapheme is independent of its
    /// edges. Regional-indicator runs also need their left origin for parity.
    private func swiftGrapheme(
        containing offset: Int,
        alignedAnchor: Int,
        isCancelled: @Sendable () -> Bool
    ) -> NSRange? {
        var radius = 128
        while true {
            if Task.isCancelled || isCancelled() { return nil }
            let start = reverseChunkStart(to: alignedAnchor, target: max(0, offset - radius))
            let rightSpan = min(length - offset, radius == Int.max ? radius : radius + 1)
            let end = forwardChunkEnd(from: start, target: offset + rightSpan)
            let text = buffer.rope.content(in: start..<end)
            if Task.isCancelled || isCancelled() { return nil }
            let first = text.unicodeScalars.first
            let firstIsRegionalIndicator = first.map { (0x1F1E6...0x1F1FF).contains($0.value) } ?? false
            let firstIsExtender = first.map(Self.isContextualGraphemeScalar) ?? false
            let boundaryNeedsEarlierContext: Bool
            if start > 0 {
                let previousStart = reverseChunkStart(to: start, target: max(0, start - 4))
                let previous = buffer.rope.content(in: previousStart..<start).unicodeScalars.last
                if let previous, let first {
                    // Ask Swift's own segmenter whether the two scalars at
                    // this edge join. This covers rules beyond category-based
                    // extenders, including Hangul and Prepend sequences.
                    let pairJoins = String(String.UnicodeScalarView([previous, first])).count == 1
                    boundaryNeedsEarlierContext = pairJoins || Self.isContextualGraphemeScalar(previous)
                } else {
                    boundaryNeedsEarlierContext = false
                }
            } else {
                boundaryNeedsEarlierContext = false
            }
            var position = start
            var containing: NSRange?
            for character in text {
                if Task.isCancelled || isCancelled() { return nil }
                let next = position + String(character).utf16.count
                if position <= offset && offset < next {
                    containing = NSRange(location: position, length: next - position)
                    break
                }
                position = next
            }
            let leftContextUncertain = start > 0 &&
                (containing?.location == start || firstIsRegionalIndicator
                 || firstIsExtender || boundaryNeedsEarlierContext)
            var hasIndependentBoundary = false
            if leftContextUncertain, let containing {
                guard let found = Self.hasIndependentBoundary(
                    before: containing.location, in: text, startingAt: start,
                    isCancelled: isCancelled
                ) else { return nil }
                hasIndependentBoundary = found
            }
            if let containing,
               !(leftContextUncertain && !hasIndependentBoundary),
               !(end < length && NSMaxRange(containing) == end) {
                if Task.isCancelled || isCancelled() { return nil }
                return containing
            }
            // Reaching both document edges gives full-document segmentation.
            if start == 0 && end == length {
                if Task.isCancelled || isCancelled() { return nil }
                return containing!
            }
            radius = radius > length / 2 ? length : radius * 2
        }
    }

    /// A definite break inside the window makes segmentation after it
    /// independent of text preceding the window. Check both scalars with the
    /// same conservative context rules used at the window's left edge.
    private static func hasIndependentBoundary(
        before target: Int, in text: String, startingAt start: Int,
        isCancelled: @Sendable () -> Bool
    ) -> Bool? {
        var position = start
        var previous: Unicode.Scalar?
        var scanned = 0
        for scalar in text.unicodeScalars {
            if scanned & 255 == 0 && (Task.isCancelled || isCancelled()) { return nil }
            if position > start, position <= target, let previous,
               !(0x1F1E6...0x1F1FF).contains(scalar.value),
               !isContextualGraphemeScalar(previous),
               !isContextualGraphemeScalar(scalar),
               String(String.UnicodeScalarView([previous, scalar])).count == 2 {
                return true
            }
            previous = scalar
            position += scalar.utf16.count
            scanned += 1
            if position > target { break }
        }
        return false
    }

    private static func isContextualGraphemeScalar(_ scalar: Unicode.Scalar) -> Bool {
        // Swift's grapheme property includes extenders outside the Mark
        // categories, notably U+FF9E/U+FF9F halfwidth voiced sound marks.
        if scalar.properties.isGraphemeExtend { return true }
        if scalar.value == 0x200D || scalar.value == 0x200C
            || (0x1F3FB...0x1F3FF).contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .spacingMark, .format:
            return true
        default:
            return false
        }
    }

    private struct LocatedScalar {
        let value: Unicode.Scalar
        let scalarRange: NSRange
    }

    private static func locateScalars(
        _ text: String,
        at base: Int,
        isCancelled: @Sendable () -> Bool
    ) -> [LocatedScalar]? {
        var result: [LocatedScalar] = []
        var scalarStart = base
        for scalar in text.unicodeScalars {
            if result.count & 255 == 0 && (Task.isCancelled || isCancelled()) { return nil }
            let scalarEnd = scalarStart + scalar.utf16.count
            result.append(LocatedScalar(value: scalar,
                                        scalarRange: NSRange(location: scalarStart, length: scalarEnd - scalarStart)))
            scalarStart = scalarEnd
        }
        return result
    }
}
