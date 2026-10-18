import Foundation
import Testing
import SwiftTreeSitter
@testable import SyntaxCore

private func injectingJSON(_ query: String, child: @escaping @Sendable () -> TreeSitterSyntaxDefinition) -> TreeSitterSyntaxDefinition {
    var definition = TreeSitterSyntaxDefinition.json
    definition.injections = [TreeSitterSyntaxInjection(query: query, language: { _, _ in child() })]
    return definition
}

@Test func embeddedSpansOverrideHostAndPreserveUTF8Offsets() throws {
    let source = Data(#"["hé😀", "42", "true"]"#.utf8)
    let definition = injectingJSON("(string (string_content) @injection.content)", child: { .json })
    let highlighter = try TreeSitterSyntaxHighlighter(source: source, definition: definition)
    let spans = highlighter.highlights(in: 0..<source.count)
    #expect(spans.contains { $0.kind == .number && $0.byteRange == 13..<15 })
    #expect(spans.contains { $0.kind == .constant && String(decoding: source[$0.byteRange], as: UTF8.self) == "true" })
    #expect(spans.contains { $0.kind == .string && String(decoding: source[$0.byteRange], as: UTF8.self).contains("hé😀") })
    for (left, right) in zip(spans, spans.dropFirst()) { #expect(left.byteRange.upperBound <= right.byteRange.lowerBound) }
}

@Test func invalidInjectionQueriesAndChildDefinitionsPreserveHost() throws {
    let source = Data(#"{"name":"42"}"#.utf8)
    let baseline = try TreeSitterSyntaxHighlighter(source: source, definition: .json).highlights(in: 0..<source.count)
    var badChild = TreeSitterSyntaxDefinition.json
    badChild = TreeSitterSyntaxDefinition(language: badChild.language, highlightQuery: "(nonexistent_node) @number", captures: badChild.captures)
    let invalid = badChild
    let definitions = [
        injectingJSON("(nonexistent_node) @injection.content", child: { .json }),
        injectingJSON("((string) @injection.content (#set! injection.language \"json\"))", child: { .json }),
        injectingJSON("(string (string_content) @injection.content)", child: { invalid })
    ]
    for definition in definitions {
        let actual = try TreeSitterSyntaxHighlighter(source: source, definition: definition).highlights(in: 0..<source.count)
        #expect(actual == baseline)
    }
}

private func recursiveInjectionDefinition() -> TreeSitterSyntaxDefinition {
    injectingJSON("(document) @injection.content", child: { recursiveInjectionDefinition() })
}

@Test func recursiveInjectionsStopAtDepthLimit() throws {
    let highlighter = try TreeSitterSyntaxHighlighter(source: Data("42".utf8), definition: recursiveInjectionDefinition())
    #expect(highlighter.highlights(in: 0..<2) == [SyntaxHighlightSpan(byteRange: 0..<2, kind: .number)])
}

@Test func failedEmbeddedRegionDoesNotSuppressSuccessfulSibling() throws {
    var definition = TreeSitterSyntaxDefinition.json
    definition.injections = [TreeSitterSyntaxInjection(
        query: "(string (string_content) @injection.content)",
        language: { node, source in
            let bytes = node.byteRange
            if String(decoding: source[Int(bytes.lowerBound)..<Int(bytes.upperBound)], as: UTF8.self) == "bad" {
                return TreeSitterSyntaxDefinition(language: TreeSitterSyntaxDefinition.json.language,
                    highlightQuery: "(nonexistent_node) @number", captures: [:])
            }
            return .json
        }
    )]
    let source = Data(#"["bad", "42"]"#.utf8)
    let spans = try TreeSitterSyntaxHighlighter(source: source, definition: definition).highlights(in: 0..<source.count)
    #expect(spans.contains { $0.kind == .number && String(decoding: source[$0.byteRange], as: UTF8.self) == "42" })
    #expect(spans.contains { $0.kind == .string && String(decoding: source[$0.byteRange], as: UTF8.self).contains("bad") })
}

@Test func includedRangesClipTokensAcrossExcludedSourceBytes() throws {
    let ranges = [
        TSRange(points: Point(row: 0, column: 0)..<Point(row: 0, column: 2), bytes: 0..<2),
        TSRange(points: Point(row: 0, column: 4)..<Point(row: 0, column: 6), bytes: 4..<6)
    ]
    let definition = TreeSitterSyntaxDefinition(language: TreeSitterSyntaxDefinition.json.language,
        highlightQuery: "(document) @string", captures: TreeSitterSyntaxDefinition.codeCaptures)
    let highlighter = try TreeSitterSyntaxHighlighter(source: Data("12xx34".utf8), definition: definition,
                                                    includedRanges: ranges)
    #expect(highlighter.highlights(in: 0..<6) == [
        SyntaxHighlightSpan(byteRange: 0..<2, kind: .string),
        SyntaxHighlightSpan(byteRange: 4..<6, kind: .string)
    ])
    #expect(highlighter.highlights(in: 2..<4).isEmpty)
    let empty = try TreeSitterSyntaxHighlighter(source: Data("42".utf8), definition: .json, includedRanges: [])
    #expect(empty.highlights(in: 0..<2).isEmpty)
}
