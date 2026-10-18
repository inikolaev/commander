import Foundation
import Testing
@testable import SyntaxCore

private func definition(_ query: String) -> TreeSitterSyntaxDefinition {
    TreeSitterSyntaxDefinition(language: TreeSitterSyntaxDefinition.json.language,
                              highlightQuery: query,
                              captures: ["string": SyntaxCaptureStyle(kind: .string),
                                         "special": SyntaxCaptureStyle(kind: .property, priority: 1)])
}

private func highlightedText(_ source: String, query: String) throws -> [String] {
    let data = Data(source.utf8)
    let highlighter = try TreeSitterSyntaxHighlighter(source: data, definition: definition(query))
    return highlighter.highlights(in: 0..<data.count).map {
        String(decoding: data[$0.byteRange], as: UTF8.self)
    }
}

@Test func predicatesFilterCapturesUsingUTF8Positions() throws {
    let source = "[\"é\",\"keep\",\"skip\",\n\"éclair\",\"keep\"]"
    #expect(try highlightedText(source, query: #"((string_content) @string (#eq? @string "keep"))"#)
            == ["keep", "keep"])
    #expect(try highlightedText(source, query: #"((string_content) @string (#match? @string "^é"))"#)
            == ["é", "éclair"])
    #expect(try highlightedText(source, query: #"((string_content) @string (#not-eq? @string "keep"))"#)
            == ["é", "skip", "éclair"])
    #expect(try highlightedText(source, query: #"((string_content) @string (#any-of? @string "é" "skip"))"#)
            == ["é", "skip"])
}

@Test func predicatesCanReadMultilineNodes() throws {
    #expect(try highlightedText("[\n  \"é\"\n]", query: #"((array) @string (#eq? @string "[\n  \"é\"\n]"))"#)
            == ["[\n  \"é\"\n]"])
}

@Test func negativePredicatesExcludeMatchingUTF8Captures() throws {
    let source = "[\"é\",\"keep\",\n\"éclair\",\"skip\"]"
    #expect(try highlightedText(source, query: #"((string_content) @string (#not-match? @string "^é"))"#)
            == ["keep", "skip"])
    #expect(try highlightedText(source, query: #"((string_content) @string (#not-any-of? @string "é" "skip"))"#)
            == ["keep", "éclair"])
    #expect(try highlightedText(source, query: #"((string_content) @string (#not-match? @string ".*"))"#).isEmpty)
    #expect(try highlightedText(source, query: #"((string_content) @string (#not-any-of? @string "absent"))"#)
            == ["é", "keep", "éclair", "skip"])
}

@Test func multiplePredicatesMustAllPass() throws {
    #expect(try highlightedText(#"["keep","skip","keeper","other"]"#, query: #"""
    ((string_content) @string
      (#match? @string "^keep")
      (#not-any-of? @string "keeper"))
    """#) == ["keep"])
}

@Test func emptyMembershipSetsHaveDefinedSemantics() throws {
    let source = #"["x","é"]"#
    #expect(try highlightedText(source, query: #"((string_content) @string (#any-of? @string))"#).isEmpty)
    #expect(try highlightedText(source, query: #"((string_content) @string (#not-any-of? @string))"#) == ["x", "é"])
}

@Test func quantifiedCapturesRequireEveryCaptureToPass() throws {
    for predicate in [#"#eq? @string "\"keep\"""#, #"#match? @string "keep""#,
                      #"#any-of? @string "\"keep\"" "\"also\"""#,
                      #"#not-eq? @string "\"skip\"""#, #"#not-match? @string "skip""#,
                      #"#not-any-of? @string "\"skip\"" "\"other\"""#] {
        // Explicit delimiters require one match containing the whole array,
        // rather than allowing separate matches over subsets of its children.
        let query = "((array \"[\" (string) @string (\",\" (string) @string)+ \"]\") (\(predicate)))"
        let accepted = try highlightedText(#"["keep","keep"]"#, query: query)
        #expect(accepted == [#""keep""#, #""keep""#], "Predicate: \(predicate)")
        #expect(try highlightedText(#"["keep","skip"]"#, query: query).isEmpty)
        #expect(try highlightedText(#"["skip","skip"]"#, query: query).isEmpty)
        #expect(try highlightedText(#"["keep","keep","keep"]"#, query: query)
                == [#""keep""#, #""keep""#, #""keep""#])
        #expect(try highlightedText(#"["keep","keep","skip"]"#, query: query).isEmpty)
    }
}

@Test func literalEqualityUsesCanonicalUnicodeEquivalenceWithoutChangingOffsets() throws {
    let composed = "é"
    let decomposed = "e\u{301}"
    let source = "[\"\(composed)\",\"\(decomposed)\",\"e\"]"
    for predicate in [#"#eq? @string "é""#, #"#any-of? @string "é""#] {
        let tokens = try highlightedText(source, query: "((string_content) @string (\(predicate)))")
        // Compare bytes: Swift String equality alone would hide normalization changes.
        #expect(tokens.map { Array($0.utf8) } == [Array(composed.utf8), Array(decomposed.utf8)])
    }
    for predicate in [#"#not-eq? @string "é""#, #"#not-any-of? @string "é""#] {
        #expect(try highlightedText(source, query: "((string_content) @string (\(predicate)))") == ["e"])
    }
}

@Test func malformedPredicateArgumentsFallBackToPlainText() {
    for predicate in [
        "#eq? @string", "#eq? \"x\"", "#eq? @string \"x\" \"y\"",
        "#not-eq? @string", "#not-eq? @string \"x\" \"y\"",
        "#match? @string", "#match? @string \"[\"", "#match? @string \"x\" \"y\"",
        "#match? @string \"\"", "#not-match? @string \"\"",
        "#not-match? @string", "#not-match? @string \"[\"", "#not-match? @string \"x\" \"y\"",
        "#any-of? \"x\"", "#any-of? @string @special \"x\"",
        "#not-any-of? \"x\"", "#not-any-of? @string @special \"x\"",
        "#eq? \"x\" @string", "#match? \"x\" @string",
    ] {
        let query = "((string (string_content) @special) @string (\(predicate)))"
        let registry = SyntaxRegistry(languages: [SyntaxLanguageDefinition(
            id: "test", fileExtensions: ["test"],
            makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: definition(query)) }
        )])
        let highlighter = registry.highlighter(for: URL(fileURLWithPath: "/example.test"), data: Data(#""x""#.utf8))
        #expect(!highlighter.isActive, "Malformed predicate accepted: \(predicate)")
        #expect(highlighter.highlights(in: 0..<3).isEmpty)
    }
}

@Test func sharedEngineNormalizesNestedQueryCaptures() throws {
    let source = Data(#"["hello"]"#.utf8)
    let highlighter = try TreeSitterSyntaxHighlighter(source: source, definition: definition("""
    (string) @string
    (string_content) @special
    """))
    #expect(highlighter.highlights(in: 0..<source.count) == [
        SyntaxHighlightSpan(byteRange: 1..<2, kind: .string),
        SyntaxHighlightSpan(byteRange: 2..<7, kind: .property),
        SyntaxHighlightSpan(byteRange: 7..<8, kind: .string),
    ])
}

@Test func predicateTextDoesNotAliasShortUTF8NodeRanges() throws {
    // Both nodes convert to the same NSRange in the dependency's UTF-16 helper:
    // string 0..<3 and string_content 1..<2. Their predicate text must differ.
    let highlighter = try TreeSitterSyntaxHighlighter(source: Data(#""x""#.utf8), definition: definition(#"""
    ((string) @string (#eq? @string "\"x\""))
    ((string_content) @special (#eq? @special "x"))
    """#))
    #expect(highlighter.highlights(in: 0..<3) == [
        SyntaxHighlightSpan(byteRange: 0..<1, kind: .string),
        SyntaxHighlightSpan(byteRange: 1..<2, kind: .property),
        SyntaxHighlightSpan(byteRange: 2..<3, kind: .string),
    ])
}

@Test func unsupportedPredicatesAndInvalidQueriesFallBackToPlainText() {
    for query in [
        #"((string) @string (#unknown? @string "x"))"#,
        #"((string) @string (#is-not? local))"#,
        #"((string) @string (#set! priority "10"))"#,
        #"((pair key: (string) @string value: (string) @special) (#eq? @string @special))"#,
        "(nonexistent_node) @string",
    ] {
        let registry = SyntaxRegistry(languages: [SyntaxLanguageDefinition(
            id: "test", fileExtensions: ["test"],
            makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: definition(query)) }
        )])
        let highlighter = registry.highlighter(for: URL(fileURLWithPath: "/example.test"),
                                               data: Data(#"{"x":"x"}"#.utf8))
        #expect(!highlighter.isActive)
        #expect(highlighter.highlights(in: 0..<100).isEmpty)
    }
}

@Test func dataRegistryPreservesDetectionSizeLimitAndJSONPrecedence() {
    let registry = SyntaxRegistry.viewer
    let url = URL(fileURLWithPath: "/archive/member.JSON")
    let source = Data(#"{"é":"value"}"#.utf8)
    #expect(registry.supports(url))
    #expect(!registry.supports(URL(fileURLWithPath: "/member.txt")))
    #expect(!registry.highlighter(for: url, data: source, maximumFileSize: source.count - 1).isActive)
    let highlighter = registry.highlighter(for: url, data: source, maximumFileSize: source.count)
    #expect(highlighter.isActive)
    #expect(highlighter.highlights(in: 0..<source.count) == [
        SyntaxHighlightSpan(byteRange: 1..<5, kind: .property),
        SyntaxHighlightSpan(byteRange: 6..<13, kind: .string),
    ])
}
