/// One decoded source scalar and its exact, half-open source range. Adapters
/// choose the coordinate type (viewer bytes or editor UTF-16 code units).
public struct TextSearchScalar<Offset: FixedWidthInteger & Sendable>: Sendable {
    public let value: Unicode.Scalar
    public let lowerBound: Offset
    public let upperBound: Offset

    public init?(value: Unicode.Scalar, lowerBound: Offset, upperBound: Offset) {
        guard lowerBound >= 0, lowerBound < upperBound else { return nil }
        self.value = value
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

/// A barrier separates source runs that cannot form a match, such as malformed
/// UTF-8. Adapters emit scalars in the requested traversal order.
public enum TextSearchInput<Offset: FixedWidthInteger & Sendable>: Sendable {
    case scalar(TextSearchScalar<Offset>)
    case barrier
}

public enum TextSearchStep<Offset: FixedWidthInteger & Sendable>: Sendable {
    case advance
    case match(TextMatch<Offset>)
    case cancelled
}

/// A bounded-state literal scanner. Construct a fresh machine per scan; feed
/// source scalars forward or backward according to `direction`, then call
/// `finish()`. `consume` can emit at most one hit per input. In whole-word
/// mode, a hit is delayed until the following scalar or barrier establishes
/// its trailing boundary. The caller must enumerate source scalars in order,
/// without joining EOF to BOF during wraparound.
public struct LiteralSearchMachine<Offset: FixedWidthInteger & Sendable> {
    private struct TokenSpan {
        let lowerBound: Offset
        let upperBound: Offset
        let isFirstInScalar: Bool
        let isLastInScalar: Bool
        let precedingIsWord: Bool
    }

    private let direction: SearchDirection
    private let wholeWord: Bool
    private let pattern: [Unicode.Scalar]
    private let failure: [Int]
    private var ring: [TokenSpan?]
    private var nextRingIndex = 0
    private var matchedCount = 0
    private var previousIsWord = false
    private var pendingWordMatch: TextMatch<Offset>?
    private var stopped = false

    /// Counts source inputs, including barriers, so cancellation progresses
    /// even through a no-hit source. The cancellation closure is checked at
    /// the first input and every 256 inputs thereafter.
    public private(set) var processedUnits: UInt64 = 0

    /// Empty queries have no scanner and must be handled by the session.
    public init?(query: TextSearchQuery, direction: SearchDirection) {
        guard !query.isEmpty else { return nil }
        self.direction = direction
        self.wholeWord = query.wholeWord
        self.patternIsSensitive = query.caseSensitive
        let folded = query.text.unicodeScalars.flatMap {
            query.caseSensitive ? [$0] : UnicodeCaseFolding.fold($0)
        }
        self.pattern = direction == .forward ? folded : Array(folded.reversed())
        self.failure = Self.makeFailureTable(self.pattern)
        self.ring = Array(repeating: nil, count: self.pattern.count)
    }

    // These are the adapter coordinate types. Exporting their specializations
    // avoids per-scalar generic dispatch across the SwiftPM module boundary.
    @_specialize(exported: true, where Offset == Int)
    @_specialize(exported: true, where Offset == Int64)
    public mutating func consume(
        _ input: TextSearchInput<Offset>,
        isCancelled: () -> Bool = { false }
    ) -> TextSearchStep<Offset> {
        if stopped { return .cancelled }
        if processedUnits & 255 == 0 && isCancelled() {
            stopped = true
            pendingWordMatch = nil
            return .cancelled
        }
        processedUnits &+= 1

        switch input {
        case .barrier:
            let result = pendingWordMatch
            resetRun()
            return result.map(TextSearchStep.match) ?? .advance

        case .scalar(let source):
            let isWord = wholeWord && Self.isWordConstituent(source.value)
            let ready = pendingWordMatch.flatMap { isWord ? nil : $0 }
            var emitted = ready
            pendingWordMatch = nil
            let scalars = patternIsSensitive
                ? [source.value] : UnicodeCaseFolding.fold(source.value)
            let tokens = direction == .forward ? scalars : Array(scalars.reversed())
            for (index, token) in tokens.enumerated() {
                let span = TokenSpan(
                    lowerBound: source.lowerBound,
                    upperBound: source.upperBound,
                    isFirstInScalar: index == 0,
                    isLastInScalar: index == tokens.count - 1,
                    precedingIsWord: previousIsWord
                )
                insert(span)
                while matchedCount > 0 && pattern[matchedCount] != token {
                    matchedCount = failure[matchedCount - 1]
                }
                if pattern[matchedCount] == token { matchedCount += 1 }
                if matchedCount == pattern.count {
                    let start = ring[nextRingIndex]!
                    if start.isFirstInScalar && span.isLastInScalar
                        && (!wholeWord || !start.precedingIsWord) {
                        let range = direction == .forward
                            ? TextMatch(lowerBound: start.lowerBound, upperBound: span.upperBound)
                            : TextMatch(lowerBound: span.lowerBound, upperBound: start.upperBound)
                        if wholeWord {
                            pendingWordMatch = range
                        } else if emitted == nil {
                            emitted = range
                        }
                    }
                    matchedCount = failure[matchedCount - 1]
                }
            }
            previousIsWord = isWord
            return emitted.map(TextSearchStep.match) ?? .advance
        }
    }

    /// Flushes a whole-word hit at EOF/BOF. Call once after the final input.
    public mutating func finish(isCancelled: () -> Bool = { false }) -> TextSearchStep<Offset> {
        if stopped || isCancelled() {
            stopped = true
            pendingWordMatch = nil
            return .cancelled
        }
        let result = pendingWordMatch
        pendingWordMatch = nil
        return result.map(TextSearchStep.match) ?? .advance
    }

    private let patternIsSensitive: Bool

    private mutating func insert(_ span: TokenSpan) {
        ring[nextRingIndex] = span
        nextRingIndex = (nextRingIndex + 1) % ring.count
    }

    private mutating func resetRun() {
        pendingWordMatch = nil
        matchedCount = 0
        previousIsWord = false
        nextRingIndex = 0
    }

    private static func makeFailureTable(_ pattern: [Unicode.Scalar]) -> [Int] {
        var table = Array(repeating: 0, count: pattern.count)
        var length = 0
        for index in pattern.indices.dropFirst() {
            while length > 0 && pattern[index] != pattern[length] {
                length = table[length - 1]
            }
            if pattern[index] == pattern[length] { length += 1 }
            table[index] = length
        }
        return table
    }

    private static func isWordConstituent(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value == 0x200C || scalar.value == 0x200D { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
             .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .connectorPunctuation:
            return true
        default:
            return false
        }
    }
}
