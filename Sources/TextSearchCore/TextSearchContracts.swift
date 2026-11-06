/// The order in which a source adapter enumerates literal matches.
/// Direction does not imply wraparound; document navigation owns that policy.
public enum SearchDirection: Sendable {
    case forward
    case backward
}

/// A literal query. Whitespace is significant and is never trimmed.
/// An empty `text` clears results; callers must not start a scan for it.
public struct TextSearchQuery: Sendable, Equatable {
    public let text: String
    public let caseSensitive: Bool
    public let wholeWord: Bool

    public init(text: String, caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }

    public var isEmpty: Bool { text.isEmpty }

    /// A source scalar contributes at least one matcher token. This is the
    /// largest number of source scalars a complete match can occupy; adapters
    /// multiply it by their encoding's maximum units per scalar when seeking
    /// around an anchor or bounded wrap interval.
    public var maximumMatchSourceScalars: Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let tokens = caseSensitive ? 1 : UnicodeCaseFolding.fold(scalar).count
            let (next, overflow) = count.addingReportingOverflow(tokens)
            if overflow { return Int.max }
            count = next
        }
        return count
    }

    /// String equality normalizes canonically equivalent spellings. Literal
    /// matching does not, so query identity compares the actual scalar stream.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.caseSensitive == rhs.caseSensitive
            && lhs.wholeWord == rhs.wholeWord
            && lhs.text.unicodeScalars.elementsEqual(rhs.text.unicodeScalars)
    }
}

/// A nonempty, half-open range in the source adapter's own coordinates.
/// `Int64` represents viewer source byte offsets; `Int` represents editor
/// UTF-16 offsets. This type never converts between those coordinate systems.
public struct TextMatch<Offset: FixedWidthInteger & Sendable>: Sendable, Equatable {
    public let lowerBound: Offset
    public let upperBound: Offset

    /// Returns nil for a negative start, empty range, or reversed range.
    public init?(lowerBound: Offset, upperBound: Offset) {
        guard lowerBound >= 0, lowerBound < upperBound else { return nil }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}
