import Foundation
import Testing
@testable import SyntaxCore

@Test func htmlBlocksHighlightAllLanguagesAtOriginalByteOffsets() throws {
    let source = #"""
    <p title="hé😀">Before</p>
    <script>
      const first = `hé ${name}`;
      console.log(42);
    </script>
    <style>
      /* café */
      .card { color: #abc; width: 12px; content: "😀"; }
    </style>
    <SCRIPT TYPE="MODULE">export const second = true;</SCRIPT>
    <script type="application/ld+json">{"name":"hé"}</script>
    <p>After</p>
    """#
    expectLanguageHighlights("mixed.html", source: source, expected: [
        (.string, "hé😀"), (.keyword, "const"), (.string, "`hé "),
        (.variable, "${name}"), (.function, "log"), (.number, "42"),
        (.comment, "/* café */"), (.property, "card"), (.property, "color"),
        (.string, "#abc"), (.number, "12"), (.type, "px"), (.string, "\"😀\""),
        (.keyword, "export"), (.constant, "true"), (.property, "\"name\""), (.string, "\"hé\"")
    ])
    let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/mixed.html"), data: Data(source.utf8))
    for token in ["42", "#abc", "export", "\"name\""] {
        let range = try #require(source.range(of: token))
        let start = source[..<range.lowerBound].utf8.count
        let spans = highlighter.highlights(in: start..<(start + 1))
        #expect(spans.contains { $0.byteRange == start..<(start + token.utf8.count) })
    }
}

@Test func htmlBlockTypesSelectOnlySupportedLanguages() {
    for attributes in ["", "type=''", "type=module", "TYPE='TEXT/JAVASCRIPT'", "type='application/javascript'", "language=JavaScript", "type='' language=vbscript"] {
        expectLanguageHighlights("typed.html", source: "<script \(attributes)>const value = 42;</script>",
                                 expected: [(.keyword, "const"), (.number, "42")])
    }
    for type in ["application/json", "application/ld+json", "importmap", "speculationrules"] {
        expectLanguageHighlights("data.html", source: "<script type='\(type)'>{\"key\":true}</script>",
                                 expected: [(.property, "\"key\""), (.constant, "true")])
    }
    for attributes in ["", "type=''", "TYPE='TEXT/CSS'"] {
        expectLanguageHighlights("typed.html", source: "<style \(attributes)>p { color: #fff; }</style>",
                                 expected: [(.property, "color"), (.string, "#fff")])
    }
}

@Test func htmlUnsupportedBlocksAndInlineAttributesKeepHostHighlighting() throws {
    for (tag, attributes) in [("script", "type='text/template'"), ("script", "type='text/plain'"),
                              ("script", "src='app.js'"), ("script", "language=vbscript"),
                              ("script", "type='text/plain' type='module'"), ("style", "type='text/less'")] {
        let source = "<\(tag) \(attributes)>const ignored = 123;</\(tag)><script>const valid = 42;</script>"
        let data = Data(source.utf8)
        let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/test.html"), data: data)
        #expect(highlighter.isActive)
        let start = try #require(source.range(of: "const ignored"))
        let offset = source[..<start.lowerBound].utf8.count
        #expect(highlighter.highlights(in: offset..<(offset + 20)).isEmpty)
        #expect(highlighter.highlights(in: 0..<data.count).contains {
            $0.kind == .number && String(decoding: data[$0.byteRange], as: UTF8.self) == "42"
        })
    }
    expectLanguageHighlights("inline.html", source: "<p style='color: red' onclick='return false'>Text</p>",
                             expected: [(.string, "color: red"), (.string, "return false")])
}

@Test func htmlEmptyAndMalformedBlocksDoNotSuppressOtherRegions() {
    expectLanguageHighlights("broken.html", source: """
    <script></script><style></style>
    <script>const broken = ;</script>
    <style>p { color: #fff; }</style>
    <script>const valid = 42;</script><p title="after">After</p>
    """, expected: [(.property, "color"), (.string, "#fff"), (.number, "42"), (.string, "after")])
}

@Test func htmlGrammarOwnsEmbeddedBlockBoundaries() throws {
    let source = #"<script>const value = "</script>"; const outside = 123;<style>p { color: #abc; }</style>"#
    let data = Data(source.utf8)
    let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/boundary.html"), data: data)
    let token = try #require(source.range(of: "const outside"))
    let start = source[..<token.lowerBound].utf8.count
    #expect(highlighter.highlights(in: start..<(start + source[token].utf8.count)).isEmpty)
    #expect(highlighter.highlights(in: 0..<data.count).contains {
        $0.kind == .string && String(decoding: data[$0.byteRange], as: UTF8.self) == "#abc"
    })
}
