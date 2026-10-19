import Foundation
import EditorCore
import SyntaxCore

struct EditorSyntaxHighlight: Sendable, Equatable {
    let range: Range<Int> // UTF-16 document offsets, on grapheme boundaries.
    let kind: SyntaxKind
}

/// Immutable drawing index for one exact document version.
struct EditorSyntaxProjection: Sendable {
    static let empty = EditorSyntaxProjection(highlights: [])
    let highlights: [EditorSyntaxHighlight]
    /// Parser-confirmed, simple quoted tokens that can safely keep their color
    /// for identifier characters typed inside them while the next parse runs.
    var inheritableTokens: [Range<Int>] = []

    static func make(source: String, highlighter: any SyntaxHighlighter) -> Self {
        guard highlighter.isActive else { return .empty }
        let spans = highlighter.highlights(in: 0..<source.utf8.count)
        guard !spans.isEmpty else { return .empty }
        var result: [EditorSyntaxHighlight] = []
        var byte = 0
        var utf16 = 0
        var index = 0
        // Iterate Characters, not scalars: a token boundary inside a composed
        // grapheme colors the entire glyph and can never split its drawing.
        for character in source {
            let text = String(character)
            let nextByte = byte + text.utf8.count
            let nextUTF16 = utf16 + text.utf16.count
            while index < spans.count && spans[index].byteRange.upperBound <= byte { index += 1 }
            if index < spans.count, spans[index].byteRange.lowerBound < nextByte,
               spans[index].byteRange.upperBound > byte {
                let kind = spans[index].kind
                if let last = result.last, last.kind == kind, last.range.upperBound == utf16 {
                    result[result.count - 1] = EditorSyntaxHighlight(range: last.range.lowerBound..<nextUTF16, kind: kind)
                } else {
                    result.append(EditorSyntaxHighlight(range: utf16..<nextUTF16, kind: kind))
                }
            }
            byte = nextByte
            utf16 = nextUTF16
        }
        let utf16Source = source as NSString
        let tokens = result.compactMap { highlight -> Range<Int>? in
            guard highlight.kind == .property || highlight.kind == .string,
                  highlight.range.count >= 2 else { return nil }
            let token = utf16Source.substring(with: NSRange(
                location: highlight.range.lowerBound, length: highlight.range.count))
            let scalars = Array(token.unicodeScalars)
            guard scalars.first?.value == 0x22,
                  scalars.last?.value == 0x22,
                  scalars.dropFirst().dropLast().allSatisfy({ isIdentifierScalar($0.value) }) else { return nil }
            // A prefix such as Python r/f or C++ R can change how an apparent
            // quoted range is parsed. Require a standalone opening delimiter.
            if highlight.range.lowerBound > 0 {
                let previous = utf16Source.character(at: highlight.range.lowerBound - 1)
                guard !isIdentifierScalar(UInt32(previous)) else { return nil }
            }
            return highlight.range
        }
        return Self(highlights: result, inheritableTokens: tokens)
    }

    func kind(at offset: Int) -> SyntaxKind? {
        var low = 0
        var high = highlights.count
        while low < high {
            let middle = (low + high) / 2
            if highlights[middle].range.upperBound <= offset { low = middle + 1 }
            else { high = middle }
        }
        guard low < highlights.count, highlights[low].range.lowerBound <= offset else { return nil }
        return highlights[low].kind
    }

    /// Keep colors that still describe untouched text while a parse is pending.
    /// Each delta is expressed in the coordinates left by the preceding delta.
    func applying(_ changes: [EditorContentDelta]) -> Self {
        var result = highlights
        var tokens = inheritableTokens
        for change in changes {
            let start = change.range.location
            let end = NSMaxRange(change.range)
            let insertedLength = change.insertedText.utf16.count
            let displacement = insertedLength - change.range.length
            let safeInsertion = change.range.length == 0 && Self.canContinue(change.insertedText)
            let inheritedToken = safeInsertion ? tokens.first {
                $0.lowerBound < start && start < $0.upperBound
            } : nil
            let inheritedIndex = inheritedToken.flatMap { token in
                result.firstIndex { $0.range == token }
            }
            var next: [EditorSyntaxHighlight] = []
            next.reserveCapacity(result.count + 1)
            for (index, highlight) in result.enumerated() {
                let range = highlight.range
                if range.upperBound <= start {
                    Self.append(highlight, to: &next)
                } else if range.lowerBound >= end {
                    Self.append(EditorSyntaxHighlight(
                        range: (range.lowerBound + displacement)..<(range.upperBound + displacement),
                        kind: highlight.kind), to: &next)
                } else {
                    if range.lowerBound < start {
                        Self.append(EditorSyntaxHighlight(range: range.lowerBound..<start, kind: highlight.kind), to: &next)
                    }
                    if index == inheritedIndex {
                        Self.append(EditorSyntaxHighlight(range: start..<(start + insertedLength), kind: highlight.kind), to: &next)
                    }
                    if range.upperBound > end {
                        Self.append(EditorSyntaxHighlight(
                            range: (start + insertedLength)..<(range.upperBound + displacement),
                            kind: highlight.kind), to: &next)
                    }
                }
            }
            result = next
            // A change elsewhere can alter the grammar around every token
            // (for example, deleting a property's colon). Keep visible spans,
            // but require another parse before inheriting any more colors.
            guard inheritedIndex != nil else {
                tokens.removeAll()
                continue
            }
            tokens = tokens.compactMap { token in
                if token.upperBound <= start { return token }
                if token.lowerBound >= end {
                    return (token.lowerBound + displacement)..<(token.upperBound + displacement)
                }
                // Once an edit may change the token's lexical structure, only
                // the next parser result can make it eligible again.
                guard safeInsertion, token.lowerBound < start, start < token.upperBound else { return nil }
                return token.lowerBound..<(token.upperBound + insertedLength)
            }
        }
        return Self(highlights: result, inheritableTokens: tokens)
    }

    /// ASCII identifier characters cannot terminate a simple double-quoted token.
    private static func canContinue(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { isIdentifierScalar($0.value) }
    }

    private static func isIdentifierScalar(_ value: UInt32) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) ||
            (48...57).contains(value) || value == 95
    }

    private static func append(_ highlight: EditorSyntaxHighlight, to result: inout [EditorSyntaxHighlight]) {
        guard !highlight.range.isEmpty else { return }
        if let last = result.last, last.kind == highlight.kind,
           last.range.upperBound == highlight.range.lowerBound {
            result[result.count - 1] = EditorSyntaxHighlight(
                range: last.range.lowerBound..<highlight.range.upperBound, kind: last.kind)
        } else {
            result.append(highlight)
        }
    }

    /// Joining or inserting Unicode can change grapheme boundaries adjacent to
    /// an edit. Trim provisional spans to boundaries in the current document.
    func clippingToGraphemes(in source: String) -> Self {
        var boundaries = [0]
        boundaries.reserveCapacity(source.utf16.count + 1)
        var offset = 0
        for character in source {
            offset += character.utf16.count
            boundaries.append(offset)
        }
        func firstBoundary(atOrAfter value: Int) -> Int {
            var low = 0
            var high = boundaries.count
            while low < high {
                let middle = (low + high) / 2
                if boundaries[middle] < value { low = middle + 1 } else { high = middle }
            }
            return boundaries[min(low, boundaries.count - 1)]
        }
        func lastBoundary(atOrBefore value: Int) -> Int {
            var low = 0
            var high = boundaries.count
            while low < high {
                let middle = (low + high) / 2
                if boundaries[middle] <= value { low = middle + 1 } else { high = middle }
            }
            return boundaries[max(0, low - 1)]
        }
        let clipped = highlights.compactMap { highlight -> EditorSyntaxHighlight? in
            let lower = firstBoundary(atOrAfter: highlight.range.lowerBound)
            let upper = lastBoundary(atOrBefore: highlight.range.upperBound)
            guard lower < upper else { return nil }
            return EditorSyntaxHighlight(range: lower..<upper, kind: highlight.kind)
        }
        return Self(highlights: clipped, inheritableTokens: inheritableTokens)
    }
}
