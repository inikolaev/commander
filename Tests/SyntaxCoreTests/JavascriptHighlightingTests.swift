import Foundation
import Testing
@testable import SyntaxCore

@Test func javascriptLanguageHighlights() {
    expectLanguageHighlights("sample.jsx", aliases: ["member.JS", "member.JSX", "member.MJS", "member.CJS"], source: #"""
    // greeting
    const count = 42;
    function greet(name) { return `hé ${name.toUpperCase()}!`; }
    const View = (props) => <span title="hello">{props.name}</span>;
    """#, expected: [
        (.comment, "// greeting"),
        (.keyword, "const"),
        (.number, "42"),
        (.function, "greet"),
        (.function, "toUpperCase"),
        (.function, "View"),
        (.string, "\"hello\""),
        (.property, "name"),
        (.type, "span"),
    ])
}

@Test func javascriptStringsPreserveMultilineContentAndInterpolation() throws {
    let cases: [(String, String, String, String)] = [
        ("js", "const value = `hé\n${name}\nend`;", "hé", "${name}"),
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
