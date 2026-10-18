import Foundation
import Testing
@testable import SyntaxCore

func expectLanguageHighlights(_ filename: String, aliases: [String] = [], source: String,
                              expected: [(SyntaxKind, String)],
                              sourceLocation: SourceLocation = #_sourceLocation) {
    for alias in aliases {
        expectLanguageHighlights(alias, source: source, expected: expected, sourceLocation: sourceLocation)
    }
    let data = Data(source.utf8)
    let url = URL(fileURLWithPath: "/archive/" + filename)
    let registry = SyntaxRegistry.viewer
    #expect(registry.supports(url), sourceLocation: sourceLocation)
    let highlighter = registry.highlighter(for: url, data: data)
    #expect(highlighter.isActive, "Inactive grammar/query for \(filename)", sourceLocation: sourceLocation)
    let spans = highlighter.highlights(in: 0..<data.count)
    for (kind, token) in expected {
        #expect(spans.contains { $0.kind == kind && String(decoding: data[$0.byteRange], as: UTF8.self) == token },
                "Missing \(kind) token '\(token)' in \(filename)", sourceLocation: sourceLocation)
    }
    for (left, right) in zip(spans, spans.dropFirst()) {
        #expect(left.byteRange.upperBound <= right.byteRange.lowerBound, sourceLocation: sourceLocation)
    }
    #expect(spans.allSatisfy { !$0.byteRange.isEmpty && $0.byteRange.upperBound <= data.count }, sourceLocation: sourceLocation)
    #expect(!registry.highlighter(for: url, data: data, maximumFileSize: 0).isActive, sourceLocation: sourceLocation)
}

@Test func languageDefinitionMatchesExactFilenamesAndCaseInsensitiveExtensions() {
    let registry = SyntaxRegistry(languages: [SyntaxLanguageDefinition(
        id: "test", fileExtensions: ["test"], fileNames: ["BUILD"],
        makeHighlighter: { _ in PlainTextSyntaxHighlighter.shared }
    )])
    #expect(registry.supports(URL(fileURLWithPath: "/archive/BUILD")))
    #expect(!registry.supports(URL(fileURLWithPath: "/archive/build")))
    #expect(registry.supports(URL(fileURLWithPath: "/archive/file.TEST")))
    #expect(!registry.supports(URL(fileURLWithPath: "/archive/BUILD.txt")))
}
