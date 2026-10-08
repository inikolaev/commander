import FileManagerCore
import Foundation
import SyntaxCore

struct ViewerDisplayHighlight: Sendable, Equatable {
    let range: Range<Int>
    let kind: SyntaxKind
}

struct ViewerSyntaxProjection: Sendable {
    static let empty = ViewerSyntaxProjection(lines: [])
    let lines: [[ViewerDisplayHighlight]]

    static func make(page: ViewerPage, highlighter: any SyntaxHighlighter) -> ViewerSyntaxProjection {
        guard highlighter.isActive, page.mode == .text,
              let first = page.lines.first, let last = page.lines.last else {
            return ViewerSyntaxProjection(lines: Array(repeating: [], count: page.lines.count))
        }

        // Position in the immutable syntax stream once for the whole page. From
        // here both the row stream and the syntax-span stream only move forward.
        let pageRange = Int(first.offset)..<Int(last.endOffset)
        let spans = highlighter.highlights(in: pageRange)
        var spanIndex = 0
        var projected: [[ViewerDisplayHighlight]] = []
        projected.reserveCapacity(page.lines.count)

        for line in page.lines {
            guard let source = line.sourceText else {
                projected.append([])
                continue
            }

            let lineStart = Int(line.offset)
            let lineEnd = Int(line.endOffset)
            while spanIndex < spans.count && spans[spanIndex].byteRange.upperBound <= lineStart {
                spanIndex += 1
            }

            var lineSpans: [SyntaxHighlightSpan] = []
            var cursor = spanIndex
            while cursor < spans.count && spans[cursor].byteRange.lowerBound < lineEnd {
                let span = spans[cursor]
                if span.byteRange.upperBound > lineStart {
                    lineSpans.append(span)
                }
                cursor += 1
            }
            projected.append(project(source: source, lineStart: lineStart, lineEnd: lineEnd, spans: lineSpans))

            // A span can cross a wrapped-row boundary, so only consume spans that
            // are completely behind this row.
            while spanIndex < spans.count && spans[spanIndex].byteRange.upperBound <= lineEnd {
                spanIndex += 1
            }
        }

        return ViewerSyntaxProjection(lines: projected)
    }

    private static func project(
        source: String,
        lineStart: Int,
        lineEnd: Int,
        spans: [SyntaxHighlightSpan]
    ) -> [ViewerDisplayHighlight] {
        guard !spans.isEmpty else { return [] }

        var result: [ViewerDisplayHighlight] = []
        result.reserveCapacity(spans.count)

        var iterator = source.makeIterator()
        var sourceByte = lineStart
        var displayOffset = 0
        var layoutColumn = 0

        func advance(to target: Int) {
            let target = min(max(target, lineStart), lineEnd)
            while sourceByte < target, let character = iterator.next() {
                let rendered = renderedCharacter(character, layoutColumn: layoutColumn)
                sourceByte += String(character).utf8.count
                displayOffset += rendered.displayCount
                layoutColumn += rendered.columnWidth
            }
        }

        for span in spans {
            let lower = max(lineStart, span.byteRange.lowerBound)
            let upper = min(lineEnd, span.byteRange.upperBound)
            guard lower < upper else { continue }

            advance(to: lower)
            let displayStart = displayOffset
            advance(to: upper)
            if displayStart < displayOffset {
                result.append(ViewerDisplayHighlight(range: displayStart..<displayOffset, kind: span.kind))
            }
        }

        return result
    }

    private static func renderedCharacter(_ character: Character, layoutColumn: Int)
        -> (displayCount: Int, columnWidth: Int) {
        let scalars = character.unicodeScalars
        if scalars.count == 1, scalars.first == "\t" {
            let width = 4 - layoutColumn % 4
            return (width, width)
        }

        var rendered = ""
        var columnWidth = 0
        for scalar in scalars {
            rendered += CharacterSet.controlCharacters.contains(scalar) ? "·" : String(scalar)
            columnWidth += 1
        }
        return (rendered.count, columnWidth)
    }
}
