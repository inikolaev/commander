import Foundation
import Testing
@testable import SyntaxCore

private func verifyEdits(_ filename: String, initial: String,
                         batches: [[SyntaxEditingDelta]], registry: SyntaxRegistry = .viewer) async throws {
    let url = URL(fileURLWithPath: "/\(filename)")
    let session = registry.editingSession(for: url, data: Data(initial.utf8))
    var text = initial
    func equal(_ actual: any SyntaxHighlighter, _ source: String) {
        let data = Data(source.utf8)
        let fresh = registry.highlighter(for: url, data: data)
        #expect(actual.isActive == fresh.isActive)
        #expect(actual.highlights(in: 0..<data.count) == fresh.highlights(in: 0..<data.count))
        for offset in stride(from: 0, to: data.count, by: max(1, data.count / 11)) {
            #expect(actual.highlights(in: offset..<min(data.count, offset + 1)) ==
                    fresh.highlights(in: offset..<min(data.count, offset + 1)))
        }
    }
    equal(await session.highlighter(), text)
    for batch in batches {
        for delta in batch {
            text = (text as NSString).replacingCharacters(in: delta.range, with: delta.insertedText)
        }
        let snapshot = try await session.apply(batch)
        equal(snapshot, text)
    }
}

private func delta(_ text: String, _ old: String, _ replacement: String) -> SyntaxEditingDelta {
    SyntaxEditingDelta(range: (text as NSString).range(of: old), insertedText: replacement)
}

@Test func editingSessionMatchesFreshJSONAcrossUnicodeAndOrderedUndoBatch() async throws {
    let initial = "é😀\n{\"one\":1,\n\"two\":2}\n"
    try await verifyEdits("sample.json", initial: initial, batches: [
        [delta(initial, "é😀", "a")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 0), insertedText: "\nβ")],
        [SyntaxEditingDelta(range: NSRange(location: 2, length: 0), insertedText: "😀"),
         SyntaxEditingDelta(range: NSRange(location: 2, length: 2), insertedText: "é")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 0), insertedText: "")]
    ])
}

@Test func editingSessionReevaluatesPredicates() async throws {
    let definition = TreeSitterSyntaxDefinition(
        language: TreeSitterSyntaxDefinition.json.language,
        highlightQuery: #"((string_content) @special (#eq? @special "keep"))"#,
        captures: ["special": SyntaxCaptureStyle(kind: .property)])
    let registry = SyntaxRegistry(languages: [SyntaxLanguageDefinition(
        id: "predicate", fileExtensions: ["pred"], syntax: { definition })])
    let initial = "[\"é\",\"skip\",\n\"keep\"]"
    try await verifyEdits("sample.pred", initial: initial, batches: [
        [delta(initial, "skip", "keep")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 0), insertedText: "\n")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 1), insertedText: "")]
    ], registry: registry)
}

@Test func editingSessionUsesCustomHighlighterFactoryAfterEdits() async throws {
    let registry = SyntaxRegistry(languages: [SyntaxLanguageDefinition(
        id: "custom-json", fileExtensions: ["custom"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .json) })])
    let initial = "{\"first\": 1}"
    try await verifyEdits("sample.custom", initial: initial, batches: [
        [delta(initial, "first", "second")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 0), insertedText: "\n😀")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 3), insertedText: "")]
    ], registry: registry)
}

@Test func customEditingSessionFallsBackOnSizeAndFactoryError() async throws {
    enum FactoryError: Error { case rejected }
    let registry = SyntaxRegistry(languages: [SyntaxLanguageDefinition(
        id: "custom-json", fileExtensions: ["custom"], makeHighlighter: { source in
            if source.contains(33) { throw FactoryError.rejected }
            return try TreeSitterSyntaxHighlighter(source: source, definition: .json)
        })])
    let session = registry.editingSession(for: URL(fileURLWithPath: "/sample.custom"),
                                          data: Data("{}".utf8), maximumFileSize: 4)
    #expect(await session.highlighter().isActive)
    #expect(!(try await session.apply([SyntaxEditingDelta(range: NSRange(location: 1, length: 0), insertedText: "!")])).isActive)
    #expect((try await session.apply([SyntaxEditingDelta(range: NSRange(location: 1, length: 1), insertedText: "")])).isActive)
    #expect(!(try await session.apply([SyntaxEditingDelta(range: NSRange(location: 1, length: 0), insertedText: "abc")])).isActive)
    #expect((try await session.apply([SyntaxEditingDelta(range: NSRange(location: 1, length: 3), insertedText: "")])).isActive)
}

@Test func editingSessionRecomputesHTMLAndMarkdownInjections() async throws {
    let html = "<script type='text/javascript'>const x = 42;</script>\n"
    try await verifyEdits("sample.html", initial: html, batches: [
        [delta(html, "text/javascript", "application/ld+json")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 0), insertedText: "<p>😀</p>\n")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 10), insertedText: "")]
    ])
    let markdown = "# Hé😀\n```js\nconst x = 42;\n```\n"
    try await verifyEdits("sample.md", initial: markdown, batches: [
        [delta(markdown, "js", "json")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 0), insertedText: "> ")],
        [SyntaxEditingDelta(range: NSRange(location: 0, length: 2), insertedText: "")]
    ])
}

@Test func editingSessionSizeFallbackRecoversAndRejectsInvalidUTF16() async throws {
    let url = URL(fileURLWithPath: "/sample.json")
    let session = SyntaxRegistry.viewer.editingSession(for: url, data: Data("{}".utf8), maximumFileSize: 5)
    let initial = await session.highlighter()
    #expect(initial.isActive)
    let oversized = try await session.apply([SyntaxEditingDelta(range: NSRange(location: 1, length: 0), insertedText: "😀")])
    #expect(!oversized.isActive)
    await #expect(throws: SyntaxEditingError.self) {
        try await session.apply([SyntaxEditingDelta(range: NSRange(location: 2, length: 0), insertedText: "x")])
    }
    let recovered = try await session.apply([SyntaxEditingDelta(range: NSRange(location: 1, length: 2), insertedText: "")])
    #expect(recovered.isActive)
    #expect(recovered.highlights(in: 0..<2) == SyntaxRegistry.viewer.highlighter(for: url, data: Data("{}".utf8)).highlights(in: 0..<2))
    #expect(initial.highlights(in: 0..<2) == recovered.highlights(in: 0..<2))
}
