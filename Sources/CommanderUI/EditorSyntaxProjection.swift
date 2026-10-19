import Foundation
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
}
