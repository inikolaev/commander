import SwiftTreeSitter

/// Excludes host syntax (for example blockquote prefixes) without rewriting
/// source bytes, and clips embedded tokens so they cannot color those gaps.
enum SyntaxInjectionRanges {
    static func included(in node: Node, excluding types: Set<String>, inherited: [TSRange]? = nil) -> [TSRange]? {
        let excluded = (0..<node.namedChildCount).compactMap { node.namedChild(at: $0) }
            .filter { types.contains($0.nodeType ?? "") }
        guard !excluded.isEmpty || inherited != nil else { return nil }
        var start = node.byteRange.lowerBound
        var point = node.pointRange.lowerBound
        var allowed: [TSRange] = []
        func append(until end: UInt32, point endPoint: Point) {
            guard start < end else { return }
            allowed.append(TSRange(points: point..<endPoint, bytes: start..<end))
        }
        for child in excluded {
            append(until: child.byteRange.lowerBound, point: child.pointRange.lowerBound)
            start = child.byteRange.upperBound
            point = child.pointRange.upperBound
        }
        append(until: node.byteRange.upperBound, point: node.pointRange.upperBound)
        if let inherited { allowed = intersection(allowed, inherited) }
        // Intersect in the parent's coordinate system before translating both
        // byte offsets and Tree-sitter row/column positions into the child slice.
        let origin = node.pointRange.lowerBound
        func local(_ point: Point) -> Point {
            Point(row: point.row - origin.row,
                  column: point.row == origin.row ? point.column - origin.column : point.column)
        }
        return allowed.map {
            TSRange(points: local($0.points.lowerBound)..<local($0.points.upperBound),
                    bytes: ($0.bytes.lowerBound - node.byteRange.lowerBound)..<($0.bytes.upperBound - node.byteRange.lowerBound))
        }
    }

    private static func intersection(_ local: [TSRange], _ inherited: [TSRange]) -> [TSRange] {
        guard let first = local.first else { return [] }
        // A document can have many exclusions and many injected regions. Start
        // at the first relevant inherited range rather than rescanning all rows.
        var low = 0
        var high = inherited.count
        while low < high {
            let middle = (low + high) / 2
            if inherited[middle].bytes.upperBound <= first.bytes.lowerBound { low = middle + 1 }
            else { high = middle }
        }
        var i = 0
        var j = low
        var result: [TSRange] = []
        while i < local.count && j < inherited.count {
            let a = local[i], b = inherited[j]
            let lower = max(a.bytes.lowerBound, b.bytes.lowerBound)
            let upper = min(a.bytes.upperBound, b.bytes.upperBound)
            if lower < upper {
                let start = a.bytes.lowerBound >= b.bytes.lowerBound ? a.points.lowerBound : b.points.lowerBound
                let end = a.bytes.upperBound <= b.bytes.upperBound ? a.points.upperBound : b.points.upperBound
                result.append(TSRange(points: start..<end, bytes: lower..<upper))
            }
            if a.bytes.upperBound <= b.bytes.upperBound { i += 1 } else { j += 1 }
        }
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
