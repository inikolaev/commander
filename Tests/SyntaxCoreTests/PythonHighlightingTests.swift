import Foundation
import Testing
@testable import SyntaxCore

@Test func pythonLanguageHighlights() {
    expectLanguageHighlights("sample.PY", aliases: ["member.PY", "member.PYI", "member.PYW"], source: #"""
    # greeting
    class Greeter:
        def greet(self, name: str):
            count = 42
            enabled = True
            return f"hé {name.upper()}!"
    """#, expected: [
        (.comment, "# greeting"),
        (.keyword, "class"),
        (.type, "Greeter"),
        (.function, "greet"),
        (.type, "str"),
        (.number, "42"),
        (.constant, "True"),
        (.function, "upper"),
    ])
}

@Test func pythonStringsPreserveMultilineContentAndInterpolation() throws {
    let cases: [(String, String, String, String)] = [
        ("py", "value = f\"\"\"hé\n{name}\nend\"\"\"", "hé", "{name}"),
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
