import Foundation
import SwiftTreeSitter
import TreeSitter

struct SyntaxCaptureStyle: Sendable {
    let kind: SyntaxKind
    var priority: Int = 0
}

/// Language-specific inputs; parsing, predicate evaluation and indexing are shared.
struct TreeSitterSyntaxDefinition: Sendable {
    let language: Language
    let highlightQuery: String
    let captures: [String: SyntaxCaptureStyle]
    var injections: [TreeSitterSyntaxInjection] = []
}

struct TreeSitterSyntaxHighlighter: SyntaxHighlighter {
    let isActive = true
    private let index: SyntaxSpanIndex

    init(source: Data, definition: TreeSitterSyntaxDefinition, injectionDepth: Int = 0,
         includedRanges: [SwiftTreeSitter.TSRange]? = nil) throws {
        if includedRanges?.isEmpty == true {
            index = SyntaxSpanIndex(captures: [])
            return
        }
        let parser = Parser()
        try parser.setLanguage(definition.language)
        if let includedRanges { parser.includedRanges = includedRanges }
        let oldTree: Tree? = nil
        guard let tree = parser.parse(tree: oldTree, encoding: TSInputEncodingUTF8, readBlock: { offset, _ in
            guard offset < source.count else { return nil }
            return source.subdata(in: offset..<min(source.count, offset + 64 * 1024))
        }) else { throw SyntaxHighlightingError.parseFailed }

        let query = try Query(language: definition.language, data: Data(definition.highlightQuery.utf8))
        if query.hasPredicates { try SyntaxPredicateValidator.validate(definition) }
        let text = query.hasPredicates ? UTF8PredicateText(source: source) : nil
        let context = Predicate.Context(textProvider: { _, points in text?.string(in: points) })
        let cursor = query.execute(in: tree)
        var captures: [SyntaxCapture] = []
        while let match = cursor.next() {
            // Resolve with the dependency's predicate API directly: its resolving
            // sequence caches by UTF-16 NSRange, which can alias UTF-8 node ranges.
            guard match.allowed(in: context) else { continue }
            for capture in match.captures {
                guard let name = capture.name, let style = definition.captures[name] else { continue }
                let range = capture.node.byteRange
                captures.append(SyntaxCapture(
                    span: SyntaxHighlightSpan(
                        byteRange: Int(range.lowerBound)..<Int(range.upperBound), kind: style.kind),
                    priority: style.priority
                ))
            }
        }
        let composed = TreeSitterInjectionHighlighter.compose(
            captures: captures, source: source, tree: tree, language: definition.language,
            injections: definition.injections, depth: injectionDepth, includedRanges: includedRanges)
        index = SyntaxSpanIndex(captures: includedRanges.map {
            SyntaxInjectionRanges.clip(composed, to: $0)
        } ?? composed)
    }

    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] {
        index.highlights(in: byteRange)
    }
}

/// SwiftTreeSitter's NSRange convenience conversion assumes UTF-16. Our parser
/// uses UTF-8, so resolve text through points whose columns are byte offsets.
private struct UTF8PredicateText {
    let source: Data
    let lineStarts: [Int]

    init(source: Data) {
        self.source = source
        lineStarts = [0] + source.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil }
    }

    func string(in points: Range<Point>) -> String? {
        func offset(_ point: Point) -> Int? {
            let row = Int(point.row)
            guard lineStarts.indices.contains(row) else { return nil }
            let offset = lineStarts[row] + Int(point.column)
            guard offset <= source.count else { return nil }
            return offset
        }
        guard let lower = offset(points.lowerBound), let upper = offset(points.upperBound),
              lower <= upper else { return nil }
        return String(data: source.subdata(in: lower..<upper), encoding: .utf8)
    }
}

enum SyntaxHighlightingError: Error {
    case parseFailed
    case unsupportedPredicate
}
