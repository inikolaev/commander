import Foundation
import Testing
@testable import SyntaxCore

@Test func typescriptLanguageHighlights() {
    expectLanguageHighlights("sample.ts", aliases: ["member.TS", "member.MTS", "member.CTS"], source: #"""
    interface User { readonly name: string; }
    type Count = number;
    const count: Count = 42;
    function greet(user: User): string { return `hé ${user.name}`; }
    """#, expected: [
        (.keyword, "interface"),
        (.type, "User"),
        (.keyword, "readonly"),
        (.property, "name"),
        (.type, "string"),
        (.type, "Count"),
        (.type, "number"),
        (.number, "42"),
        (.function, "greet"),
    ])
}

@Test func typescriptStringsPreserveMultilineContentAndInterpolation() throws {
    let cases: [(String, String, String, String)] = [
        ("ts", "const value: string = `hé\n${name}\nend`;", "hé", "${name}"),
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
