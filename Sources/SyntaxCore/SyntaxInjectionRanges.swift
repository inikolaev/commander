import SwiftTreeSitter

/// Excludes host syntax (for example blockquote prefixes) without rewriting
/// source bytes, and clips embedded tokens so they cannot color those gaps.
enum SyntaxInjectionRanges {
    static func included(in node: Node, excluding types: Set<String>) -> [TSRange]? {
        guard !types.isEmpty else { return nil }
        let excluded = (0..<node.namedChildCount).compactMap { node.namedChild(at: $0) }
            .filter { types.contains($0.nodeType ?? "") }
        guard !excluded.isEmpty else { return nil }
        let origin = node.pointRange.lowerBound
        func local(_ point: Point) -> Point {
            Point(row: point.row - origin.row,
                  column: point.row == origin.row ? point.column - origin.column : point.column)
        }
        var start = node.byteRange.lowerBound
        var point = node.pointRange.lowerBound
        var result: [TSRange] = []
        func append(until end: UInt32, point endPoint: Point) {
            guard start < end else { return }
            result.append(TSRange(points: local(point)..<local(endPoint),
                                  bytes: (start - node.byteRange.lowerBound)..<(end - node.byteRange.lowerBound)))
        }
        for child in excluded {
            append(until: child.byteRange.lowerBound, point: child.pointRange.lowerBound)
            start = child.byteRange.upperBound
            point = child.pointRange.upperBound
        }
        append(until: node.byteRange.upperBound, point: node.pointRange.upperBound)
        return result
    }

    static func clip(_ captures: [SyntaxCapture], to ranges: [TSRange]) -> [SyntaxCapture] {
        let spans = SyntaxSpanNormalizer.normalize(captures)
        var result: [SyntaxCapture] = []
        var spanIndex = 0
        var rangeIndex = 0
        while spanIndex < spans.count && rangeIndex < ranges.count {
            let span = spans[spanIndex]
            let range = Int(ranges[rangeIndex].bytes.lowerBound)..<Int(ranges[rangeIndex].bytes.upperBound)
            let lower = max(span.byteRange.lowerBound, range.lowerBound)
            let upper = min(span.byteRange.upperBound, range.upperBound)
            if lower < upper {
                result.append(SyntaxCapture(span: SyntaxHighlightSpan(byteRange: lower..<upper, kind: span.kind), priority: 0))
            }
            if span.byteRange.upperBound <= range.upperBound { spanIndex += 1 }
            else { rangeIndex += 1 }
        }
        return result
    }
}
