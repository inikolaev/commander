import Foundation
import Testing
@testable import SyntaxCore

@Test func markdownHighlightsBlockAndInlineSyntax() {
    expectLanguageHighlights("README.md", aliases: ["README.MD", "notes.markdown", "notes.mdown", "notes.mkd", "notes.mkdn"], source: #"""
    # Heading hé😀

    A *gentle* and **strong** word, ~~removed~~ and `let value = 1`.
    [Example](https://example.com) and ![Picture](image.png).

    - [x] Completed
    - [ ] Pending

    > A quotation

    | Key | Value |
    | --- | --- |
    | a | `code` |
    """#, expected: [
        (.keyword, "#"), (.keyword, "Heading hé😀"),
        (.property, "*gentle*"), (.constant, "**strong**"), (.comment, "~~removed~~"),
        (.string, "`let value = 1`"), (.function, "Example"), (.string, "https://example.com"),
        (.function, "Picture"), (.string, "image.png"), (.constant, "[x]"), (.constant, "[ ]"),
        (.string, "`code`")
    ])
}

@Test func markdownFencesHighlightSupportedLanguagesAndAliases() {
    let cases: [(String, String, SyntaxKind, String)] = [
        ("python", "def greet(): return 42", .function, "greet"),
        ("PY", "print(42)", .function, "print"),
        ("ruby", "def greet; 42; end", .function, "greet"),
        ("rb", "puts 'hello'", .function, "puts"),
        ("c", "int main() { return 42; }", .function, "main"),
        ("c++", "class Greeter {};", .keyword, "class"),
        ("golang", "package main", .keyword, "package"),
        ("shell", "echo hello", .function, "echo"),
        ("js", "const value = 42;", .keyword, "const"),
        ("jsx", "const node = <span />;", .type, "span"),
        ("ts", "interface Person {}", .keyword, "interface"),
        ("tsx", "const node = <span />;", .type, "span"),
        ("yml", "enabled: true", .property, "enabled"),
        ("toml", "enabled = true", .property, "enabled"),
        ("java", "class Greeter {}", .type, "Greeter"),
        ("kt", "fun greet() {}", .function, "greet"),
        ("swift", "let value = 42", .keyword, "let"),
        ("rs", "fn greet() {}", .function, "greet"),
        ("bzl", "load(\"//tools:rules.bzl\", \"rule\")", .function, "load"),
        ("css", "p { color: #fff; }", .property, "color"),
        ("json", "{\"enabled\":true}", .property, "\"enabled\""),
        ("markdown", "**strong**", .constant, "**strong**"),
        ("html", "<script>const value = 42;</script>", .keyword, "const")
    ]
    for (label, code, kind, token) in cases {
        expectLanguageHighlights("fences.md", source: "hé😀\n\n```\(label)\n\(code)\n```\n", expected: [(kind, token)])
    }
}

@Test func markdownUnknownAndUnlabelledFencesStayCode() throws {
    for label in ["", "not-a-language", "text"] {
        let source = "```\(label)\nconst ignored = 42;\n```\n\n**after**"
        let data = Data(source.utf8)
        let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/fallback.md"), data: data)
        #expect(highlighter.isActive)
        let token = try #require(source.range(of: "const ignored = 42;"))
        let start = source[..<token.lowerBound].utf8.count
        let spans = highlighter.highlights(in: start..<(start + 19))
        #expect(!spans.isEmpty && spans.allSatisfy { $0.kind == .string })
        #expect(highlighter.highlights(in: 0..<data.count).contains {
            $0.kind == .constant && String(decoding: data[$0.byteRange], as: UTF8.self) == "**after**"
        })
    }
}

@Test func markdownNestedBlockPrefixesStayOutsideInjectedTokens() throws {
    let source = #"""
    > *hé
    > continued*
    >
    > ```python
    > def greet():
    >     return "hé"
    > ```

    - ```js
      const value = 42;
      ```
    """#
    expectLanguageHighlights("nested.md", source: source, expected: [
        (.function, "greet"), (.keyword, "return"), (.string, "\"hé\""), (.number, "42")
    ])
    let data = Data(source.utf8)
    let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/nested.md"), data: data)
    for (offset, byte) in data.enumerated() where byte == 62 { // '>' blockquote markers
        let spans = highlighter.highlights(in: offset..<(offset + 1))
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { $0.kind == .keyword })
    }
    let keyword = try #require(source.range(of: "const"))
    let keywordOffset = source[..<keyword.lowerBound].utf8.count
    #expect(highlighter.highlights(in: keywordOffset..<(keywordOffset + 5)).contains { $0.kind == .keyword })
    let word = try #require(source.range(of: "continued"))
    let offset = source[..<word.lowerBound].utf8.count
    #expect(highlighter.highlights(in: offset..<(offset + 1)).contains { $0.kind == .property })
}

@Test func markdownHTMLBlocksReuseNestedJavaScriptAndCSSInjections() {
    expectLanguageHighlights("html.md", source: """
    # Before

    <script>const value = 42;</script>

    <style>p { color: #abc; }</style>

    **After**
    """, expected: [(.keyword, "const"), (.number, "42"), (.property, "color"), (.string, "#abc"), (.constant, "**After**")])
}

@Test func markdownUnclosedFenceAndEmptyDocumentRemainUsable() {
    expectLanguageHighlights("unclosed.md", source: "```js\nconst value = 42;", expected: [(.keyword, "const"), (.number, "42")])
    let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/empty.md"), data: Data())
    #expect(highlighter.isActive)
    #expect(highlighter.highlights(in: 0..<1).isEmpty)
}

@Test func markdownNestedHTMLInheritsExcludedPrefixes() {
    for body in ["let value = 1\n/ 2 / 3;", "const x = <span\nclassName='hé😀'\n/>;", "const value = `hé ${\nfoo()\n}`;"] {
        let html = "<script>\n" + body + "\n</script>"
        let quoted = html.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        func kinds(_ source: String, filename: String) -> [SyntaxKind?] {
            let data = Data(source.utf8)
            let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: filename), data: data)
            #expect(highlighter.isActive)
            var result = [SyntaxKind?](repeating: nil, count: data.count)
            for span in highlighter.highlights(in: 0..<data.count) {
                for byte in span.byteRange { result[byte] = span.kind }
            }
            return result
        }
        let expected = kinds(html, filename: "standalone.html")
        let actual = kinds(quoted, filename: "nested.md")
        var quotedOffset = 2
        for (offset, byte) in html.utf8.enumerated() {
            #expect(actual[quotedOffset] == expected[offset], "Different style at byte \(offset) for \(body)")
            quotedOffset += byte == 10 ? 3 : 1
        }
    }
}

@Test func registeredLanguageMetadataEnablesFencesWithoutMarkdownChanges() throws {
    let custom = SyntaxLanguageDefinition(id: "novel", fileExtensions: ["nvl"], aliases: ["novel-label"], syntax: { .json })
    let registry = SyntaxRegistry(languages: [.markdown, custom])
    for alias in ["novel", "NVL", "NOVEL-LABEL"] {
        for nested in [false, true] {
            let fence = "```\(alias)\n{\"answer\":42}\n```"
            let source = nested ? "````markdown\n\(fence)\n````" : fence
            let data = Data(source.utf8)
            let url = URL(fileURLWithPath: "/custom.md")
            let highlighter = registry.highlighter(for: url, data: data)
            #expect(highlighter.isActive)
            let spans = highlighter.highlights(in: 0..<data.count)
            #expect(spans.contains { $0.kind == .property && String(decoding: data[$0.byteRange], as: UTF8.self) == "\"answer\"" })
            #expect(spans.contains { $0.kind == .number && String(decoding: data[$0.byteRange], as: UTF8.self) == "42" })
            // The built-in catalog must not accidentally pick up custom entries.
            #expect(SyntaxRegistry.viewer.syntaxDefinition(forAlias: alias) == nil)
        }
    }
    // File-backed Markdown must use the same catalog as in-memory archive data.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
    let data = Data("```novel\n{\"answer\":42}\n```".utf8)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(registry.highlighter(for: url).highlights(in: 0..<data.count).contains { $0.kind == .number })
    #expect(registry.syntaxDefinition(forAlias: "python") == nil)
}

@Test func markdownClosingFencesAtEOFKeepTheirDelimiterStyle() {
    for (language, body) in [("python", "def greet(): pass"), ("html", "<script>const value = 1;</script>"), ("unknown", "plain text")] {
        for delimiter in ["```", "~~~"] {
            for ending in ["", " \t", "\n", "\r\n"] {
                let prefix = "hé😀\n\n\(delimiter)\(language)\n\(body)\n"
                let data = Data((prefix + delimiter + ending).utf8)
                let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/fence.md"), data: data)
                for offset in prefix.utf8.count..<(prefix.utf8.count + delimiter.utf8.count) {
                    let spans = highlighter.highlights(in: offset..<(offset + 1))
                    #expect(!spans.isEmpty && spans.allSatisfy { $0.kind == .keyword }, "Closing \(delimiter) for \(language), ending \(String(reflecting: ending))")
                }
            }
        }
    }
}

@Test func markdownInvalidClosingFencesAtEOFRemainCode() {
    for closing in ["``", "~~~", "``` trailing text"] {
        let prefix = "```unknown\nplain text\n"
        let data = Data((prefix + closing).utf8)
        let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/fence.md"), data: data)
        for offset in prefix.utf8.count..<data.count {
            let spans = highlighter.highlights(in: offset..<(offset + 1))
            #expect(!spans.isEmpty && spans.allSatisfy { $0.kind == .string })
        }
    }
}
