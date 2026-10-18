import Foundation
import Testing
@testable import SyntaxCore

@Test func bashLanguageHighlights() {
    expectLanguageHighlights("sample.sh", aliases: ["member.SH", "member.BASH"], source: #"""
    # greeting
    greet() {
     if true; then
      value=$((42 + 1))
      printf "hé $USER" 2>/dev/null
     fi
    }
    """#, expected: [
        (.comment, "# greeting"),
        (.function, "greet"),
        (.keyword, "if"),
        (.function, "true"),
        (.number, "42"),
        (.function, "printf"),
        (.variable, "$USER"),
        (.number, "2"),
    ])
}

@Test func bashStringsPreserveMultilineContentAndInterpolation() throws {
    let cases: [(String, String, String, String)] = [
        ("sh", "printf \"hé\n$USER\nend\"", "hé", "$USER"),
    ]
    for (ext, source, literal, embedded) in cases {
        let data = Data(source.utf8)
        let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/sample.\(ext)"), data: data)
        #expect(highlighter.isActive)
        let spans = highlighter.highlights(in: 0..<data.count)
        for (token, kind) in [(literal, SyntaxKind.string), (embedded, SyntaxKind.variable), ("end", SyntaxKind.string)] {
            let range = try #require(source.range(of: token))
            let start = source[..<range.lowerBound].utf8.count
            let end = start + token.utf8.count
            #expect(spans.contains { $0.kind == kind && $0.byteRange.lowerBound <= start && $0.byteRange.upperBound >= end },
                    "Wrong style for \(token) in \(ext)")
            // Query starting inside a multiline span must still find it.
            #expect(!highlighter.highlights(in: start..<(start + 1)).isEmpty)
        }
    }
}


@Test func shellHeredocsRespectQuotedDelimiters() throws {
    for (delimiter, expectedKind) in [("EOF", SyntaxKind.variable), ("'EOF'", SyntaxKind.string)] {
        let source = "cat <<\(delimiter)\nhello $USER\nEOF\n"
        let data = Data(source.utf8)
        let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/sample.sh"), data: data)
        #expect(highlighter.isActive)
        let token = try #require(source.range(of: "$USER"))
        let start = source[..<token.lowerBound].utf8.count
        let spans = highlighter.highlights(in: start..<(start + 5))
        #expect(spans.contains { $0.kind == expectedKind && $0.byteRange.lowerBound <= start && $0.byteRange.upperBound >= start + 5 })
    }
}
