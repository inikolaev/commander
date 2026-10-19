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
        return Self(highlights: result)
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
        for change in changes {
            let start = change.range.location
            let end = NSMaxRange(change.range)
            let insertedLength = change.insertedText.utf16.count
            let displacement = insertedLength - change.range.length
            var next: [EditorSyntaxHighlight] = []
            next.reserveCapacity(result.count + 1)
            for highlight in result {
                let range = highlight.range
                if range.upperBound <= start {
                    next.append(highlight)
                } else if range.lowerBound >= end {
                    next.append(EditorSyntaxHighlight(
                        range: (range.lowerBound + displacement)..<(range.upperBound + displacement),
                        kind: highlight.kind))
                } else {
                    if range.lowerBound < start {
                        next.append(EditorSyntaxHighlight(range: range.lowerBound..<start, kind: highlight.kind))
                    }
                    if range.upperBound > end {
                        next.append(EditorSyntaxHighlight(
                            range: (start + insertedLength)..<(range.upperBound + displacement),
                            kind: highlight.kind))
                    }
                }
            }
            result = next
        }
        return Self(highlights: result)
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
        return Self(highlights: clipped)
    }
}
