import AppKit
import EditorCore
import SyntaxCore
import Testing
@testable import Commander

private struct TestHighlighter: SyntaxHighlighter {
    let isActive = true
    let spans: [SyntaxHighlightSpan]
    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] {
        spans.filter { $0.byteRange.overlaps(byteRange) }
    }
}

@MainActor private func waitForSyntax(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for syntax projection")
}

@Test func editorProjectionMapsBytesToUTF16AndWholeGraphemes() {
    let source = "😀\t e\u{301}\nvalue"
    let highlighter = TestHighlighter(spans: [
        SyntaxHighlightSpan(byteRange: 0..<4, kind: .constant),
        SyntaxHighlightSpan(byteRange: 4..<5, kind: .comment),
        SyntaxHighlightSpan(byteRange: 7..<8, kind: .string), // combining mark inside é
        SyntaxHighlightSpan(byteRange: 8..<14, kind: .property), // newline + part of value
    ])
    let projection = EditorSyntaxProjection.make(source: source, highlighter: highlighter)
    #expect(projection.highlights == [
        EditorSyntaxHighlight(range: 0..<2, kind: .constant),
        EditorSyntaxHighlight(range: 2..<3, kind: .comment),
        EditorSyntaxHighlight(range: 4..<6, kind: .string),
        EditorSyntaxHighlight(range: 6..<11, kind: .property),
    ])
    #expect(projection.kind(at: 0) == .constant)
    #expect(projection.kind(at: 3) == nil)
    #expect(projection.kind(at: 4) == .string)
    #expect(projection.kind(at: 12) == nil)
}

@Test func editorProjectionTransformsOrderedUTF16DeltasAndClipsJoinedGraphemes() {
    let original = EditorSyntaxProjection(highlights: [
        EditorSyntaxHighlight(range: 0..<2, kind: .string),
        EditorSyntaxHighlight(range: 2..<8, kind: .property),
        EditorSyntaxHighlight(range: 10..<12, kind: .number),
    ])
    let transformed = original.applying([
        EditorContentDelta(range: NSRange(location: 4, length: 2), insertedText: "😀"),
        EditorContentDelta(range: NSRange(location: 0, length: 0), insertedText: "é"),
    ])
    #expect(transformed.highlights == [
        EditorSyntaxHighlight(range: 1..<3, kind: .string),
        EditorSyntaxHighlight(range: 3..<5, kind: .property),
        EditorSyntaxHighlight(range: 7..<9, kind: .property),
        EditorSyntaxHighlight(range: 11..<13, kind: .number),
    ])

    let joined = EditorSyntaxProjection(highlights: [
        EditorSyntaxHighlight(range: 0..<1, kind: .property),
        EditorSyntaxHighlight(range: 1..<2, kind: .number),
    ]).applying([EditorContentDelta(range: NSRange(location: 1, length: 0), insertedText: "\u{301}")])
        .clippingToGraphemes(in: "e\u{301}x")
    #expect(joined.highlights == [EditorSyntaxHighlight(range: 2..<3, kind: .number)])
}

@Test @MainActor func editorSyntaxRetainsUnaffectedColorsImmediatelyAcrossEditsAndUndo() async throws {
    let document = EditorDocuments.make(text: "{\"first\": 1, \"second\": 2}")
    var projection = EditorSyntaxProjection.empty
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/edits.json"),
                                            initialText: document.text(in: NSRange(location: 0, length: document.length))) {
        projection = $0
    }
    defer { controller.close() }
    try await waitForSyntax { projection.kind(at: 2) == .property && projection.kind(at: 14) == .property }

    document.replace(NSRange(location: 0, length: 0), with: "  ")
    #expect(projection.kind(at: 2) == nil)
    #expect(projection.kind(at: 4) == .property)
    #expect(projection.kind(at: 16) == .property)
    #expect(projection.kind(at: 0) == nil)

    document.replace(NSRange(location: 4, length: 5), with: "name")
    #expect(projection.kind(at: 4) == nil) // replacement waits for the parser
    #expect(projection.kind(at: 15) == .property) // following property shifted left
    document.undo()
    #expect(projection.kind(at: 16) == .property)
    try await waitForSyntax { projection.kind(at: 4) == .property && projection.kind(at: 16) == .property }
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "  {\"first\": 1, \"second\": 2}")
}

@Test func editorProjectionColorsOnlySafeTokenContinuations() {
    let property = EditorSyntaxProjection.make(source: "{\"name\":1}", highlighter: TestHighlighter(spans: [
        SyntaxHighlightSpan(byteRange: 1..<7, kind: .property),
    ]))
    let typed = property.applying([
        EditorContentDelta(range: NSRange(location: 3, length: 0), insertedText: "a"),
        EditorContentDelta(range: NSRange(location: 4, length: 0), insertedText: "b"),
    ])
    #expect(typed.highlights == [EditorSyntaxHighlight(range: 1..<9, kind: .property)])
    #expect(property.applying([EditorContentDelta(range: NSRange(location: 2, length: 3), insertedText: "new")])
        .kind(at: 2) == nil)
    #expect(property.applying([EditorContentDelta(range: NSRange(location: 3, length: 0), insertedText: "\\")])
        .kind(at: 3) == nil)
    #expect(property.applying([EditorContentDelta(range: NSRange(location: 1, length: 0), insertedText: "a")])
        .kind(at: 1) == nil)
    #expect(property.applying([EditorContentDelta(range: NSRange(location: 3, length: 3), insertedText: "a")])
        .kind(at: 3) == nil)

    let number = EditorSyntaxProjection(highlights: [EditorSyntaxHighlight(range: 0..<2, kind: .number)])
    #expect(number.applying([EditorContentDelta(range: NSRange(location: 1, length: 0), insertedText: "3")])
        .kind(at: 1) == nil)
    #expect(number.applying([EditorContentDelta(range: NSRange(location: 1, length: 0), insertedText: "x")])
        .kind(at: 1) == nil)
    let constant = EditorSyntaxProjection(highlights: [EditorSyntaxHighlight(range: 0..<4, kind: .constant)])
    #expect(constant.applying([EditorContentDelta(range: NSRange(location: 2, length: 0), insertedText: "x")])
        .kind(at: 2) == nil)
}

@Test func editorProjectionContinuesSimpleQuotedTokensAcrossLanguages() {
    func parsed(_ source: String, _ ext: String) -> EditorSyntaxProjection {
        let url = URL(fileURLWithPath: "/tmp/provisional.\(ext)")
        let highlighter = SyntaxRegistry.viewer.highlighter(for: url, data: Data(source.utf8))
        return EditorSyntaxProjection.make(source: source, highlighter: highlighter)
    }

    let key = parsed("{\"key\": 1}", "json")
    #expect(key.applying([EditorContentDelta(range: NSRange(location: 3, length: 0), insertedText: "x")])
        .kind(at: 3) == .property)
    #expect(key.applying([EditorContentDelta(range: NSRange(location: 3, length: 1), insertedText: "x")])
        .kind(at: 3) == nil)
    #expect(key.applying([EditorContentDelta(range: NSRange(location: 1, length: 0), insertedText: "x")])
        .kind(at: 1) == nil)

    // The JSON highlighter can return one display span for adjacent strings.
    // Such a span is not one quoted token, even when its endpoints are quotes.
    for source in ["[\"a\"\"b\"]", "[\"a\"\u{301}\"\u{301}b\"]"] {
        let projection = parsed(source, "json")
        #expect(projection.inheritableTokens.isEmpty)
        #expect(projection.applying([EditorContentDelta(range: NSRange(location: 2, length: 0), insertedText: "x")])
            .kind(at: 2) == nil)
    }

    let escaped = "{\"a\\\\\":1}"
    let escapedProjection = parsed(escaped, "json")
    #expect(escapedProjection.inheritableTokens.isEmpty)
    #expect(escapedProjection.applying([EditorContentDelta(range: NSRange(location: 4, length: 0), insertedText: "x")])
        .kind(at: 4) == nil)
    let changedEscaped = (escaped as NSString).replacingCharacters(in: NSRange(location: 4, length: 0), with: "x")
    #expect(parsed(changedEscaped, "json").kind(at: 4) != .property)
    #expect(escapedProjection.applying([EditorContentDelta(range: NSRange(location: 3, length: 1), insertedText: "x")])
        .kind(at: 3) == nil)

    let afterEscape = key.applying([
        EditorContentDelta(range: NSRange(location: 3, length: 0), insertedText: "\\"),
        EditorContentDelta(range: NSRange(location: 4, length: 0), insertedText: "x"),
    ])
    #expect(afterEscape.kind(at: 4) == nil)
    #expect(afterEscape.inheritableTokens.isEmpty)

    let afterColonDeletion = key.applying([
        EditorContentDelta(range: NSRange(location: 6, length: 1), insertedText: ""),
        EditorContentDelta(range: NSRange(location: 3, length: 0), insertedText: "x"),
    ])
    #expect(afterColonDeletion.inheritableTokens.isEmpty)
    #expect(afterColonDeletion.kind(at: 3) == nil)
    #expect(afterColonDeletion.kind(at: 2) == .property) // untouched visible text remains colored

    let afterPrefixQuote = key.applying([
        EditorContentDelta(range: NSRange(location: 1, length: 0), insertedText: "\""),
        EditorContentDelta(range: NSRange(location: 4, length: 0), insertedText: "x"),
    ])
    #expect(afterPrefixQuote.inheritableTokens.isEmpty)
    #expect(afterPrefixQuote.kind(at: 4) == nil)

    let repeatedKey = key.applying([
        EditorContentDelta(range: NSRange(location: 3, length: 0), insertedText: "x"),
        EditorContentDelta(range: NSRange(location: 4, length: 0), insertedText: "y"),
    ])
    #expect(repeatedKey.kind(at: 3) == .property && repeatedKey.kind(at: 4) == .property)
    #expect(repeatedKey.inheritableTokens == [1..<8])
    #expect(parsed("{\"kxyey\": 1}", "json").kind(at: 4) == .property)

    for (source, ext, offset) in [("value = \"abc\"", "py", 10),
                                  ("const value = \"abc\";", "js", 17)] {
        let projection = parsed(source, ext)
        #expect(projection.kind(at: offset) == .string)
        #expect(projection.applying([EditorContentDelta(range: NSRange(location: offset, length: 0),
                                                        insertedText: "x")]).kind(at: offset) == .string)
    }

    // Rust characters and Go runes are one scalar long. Extending a valid
    // single-quoted literal changes how the parser classifies the inserted text.
    for (source, ext) in [("let c = 'a';", "rs"),
                          ("package main\nvar c = 'a'", "go")] {
        let offset = (source as NSString).range(of: "'a'").location + 2
        let projection = parsed(source, ext)
        #expect(projection.kind(at: offset - 1) == .string)
        #expect(projection.inheritableTokens.isEmpty)
        #expect(projection.applying([EditorContentDelta(range: NSRange(location: offset, length: 0),
                                                        insertedText: "x")]).kind(at: offset) == nil)
        let edited = (source as NSString).replacingCharacters(
            in: NSRange(location: offset, length: 0), with: "x")
        #expect(parsed(edited, ext).kind(at: offset) != .string)
    }

    let python = parsed("r\"abc\"", "py")
    #expect(python.inheritableTokens.isEmpty)
    #expect(python.applying([EditorContentDelta(range: NSRange(location: 1, length: 0), insertedText: "x")])
        .kind(at: 1) == nil)
    #expect(parsed("rx\"abc\"", "py").kind(at: 1) != .string)
    let cpp = parsed("R\"tag(abc)tag\"", "cpp")
    #expect(cpp.inheritableTokens.isEmpty)
    #expect(cpp.applying([EditorContentDelta(range: NSRange(location: 3, length: 0), insertedText: "x")])
        .kind(at: 3) == nil)
    #expect(parsed("R\"txag(abc)tag\"", "cpp").kind(at: 3) != .string)
}

@Test @MainActor func editorSyntaxColorsJSONKeyImmediatelyThroughEditsAndUndo() async throws {
    let document = EditorDocuments.make(text: "{\"\": 12, \"value\": \"text\"}")
    var projection = EditorSyntaxProjection.empty
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/immediate.json"),
                                            initialText: document.text(in: NSRange(location: 0, length: document.length))) {
        projection = $0
    }
    defer { controller.close() }
    try await waitForSyntax { projection.kind(at: 1) == .property && projection.kind(at: 21) == .string }

    document.replace(NSRange(location: 2, length: 0), with: "a")
    #expect(projection.kind(at: 2) == .property)
    document.replace(NSRange(location: 3, length: 0), with: "b")
    #expect(projection.kind(at: 2) == .property && projection.kind(at: 3) == .property)
    #expect(projection.highlights.filter { $0.kind == .property && $0.range.contains(2) }.count == 1)
    document.undo()
    #expect(projection.kind(at: 2) == .property)
    document.redo()
    #expect(projection.kind(at: 3) == nil) // undo invalidates the guess until parsing catches up
    try await waitForSyntax { !controller.hasPendingSyntaxWork }
    #expect(projection.kind(at: 3) == .property)

    // Replacements and escapes wait for the parser to confirm the new token.
    let source = document.text(in: NSRange(location: 0, length: document.length)) as NSString
    let value = source.range(of: "text")
    document.replace(value, with: "word")
    #expect(projection.kind(at: value.location) == nil)
    document.replace(NSRange(location: value.location + 1, length: 0), with: "\\")
    #expect(projection.kind(at: value.location + 1) == nil)
    try await waitForSyntax { !controller.hasPendingSyntaxWork }
    let current = document.text(in: NSRange(location: 0, length: document.length))
    let highlighter = SyntaxRegistry.viewer.highlighter(
        for: URL(fileURLWithPath: "/tmp/immediate.json"), data: Data(current.utf8))
    #expect(projection.highlights == EditorSyntaxProjection.make(source: current, highlighter: highlighter).highlights)
    #expect(projection.kind(at: 2) == .property)
}

@Test @MainActor func editorSyntaxRapidEditsFinishWithCurrentDocumentProjection() async throws {
    let url = URL(fileURLWithPath: "/tmp/rapid.json")
    let document = EditorDocuments.make(text: "{\"key\": 1}")
    var delivered: [EditorSyntaxProjection] = []
    let controller = EditorSyntaxController(document: document, url: url, initialText: "{\"key\": 1}") {
        delivered.append($0)
    }
    defer { controller.close() }
    try await waitForSyntax { controller.hasEditingSession && !controller.hasPendingSyntaxWork }

    // Multiple edits in one actor turn must reach the parser in document order.
    document.replace(NSRange(location: 2, length: 3), with: "first")
    document.replace(NSRange(location: 7, length: 0), with: "😀")
    document.replace(NSRange(location: 12, length: 1), with: "2")
    #expect(controller.hasPendingSyntaxWork)
    // A second burst may arrive while the first update is still running.
    await Task.yield()
    document.replace(NSRange(location: 2, length: 5), with: "final")
    document.replace(NSRange(location: 7, length: 2), with: "")
    try await waitForSyntax { !controller.hasPendingSyntaxWork }

    let source = document.text(in: NSRange(location: 0, length: document.length))
    #expect(source == "{\"final\": 2}")
    let expected = EditorSyntaxProjection.make(
        source: source, highlighter: SyntaxRegistry.viewer.highlighter(for: url, data: Data(source.utf8)))
    #expect(controller.projection.highlights == expected.highlights)
    #expect(delivered.last?.highlights == expected.highlights)
}

@Test @MainActor func editorSyntaxContinuesQuotedStringsImmediatelyInOtherLanguages() async throws {
    for (source, ext) in [("value = \"abc\"", "py"), ("const value = \"abc\";", "js")] {
        let document = EditorDocuments.make(text: source)
        let offset = (source as NSString).range(of: "abc").location + 1
        var projection = EditorSyntaxProjection.empty
        let controller = EditorSyntaxController(
            document: document, url: URL(fileURLWithPath: "/tmp/immediate.\(ext)"), initialText: source
        ) { projection = $0 }
        try await waitForSyntax { projection.kind(at: offset) == .string }
        document.replace(NSRange(location: offset, length: 0), with: "x")
        #expect(projection.kind(at: offset) == .string)
        try await waitForSyntax { !controller.hasPendingSyntaxWork }
        #expect(projection.kind(at: offset) == .string)
        controller.close()
    }
}

@Test @MainActor func editorSyntaxWaitsForNestedNotificationBeforePublishing() async throws {
    let document = EditorDocuments.make(text: "{\"key\": 1}")
    let observer = document.addContentChangeObserver { change in
        if change.version == 1 {
            document.replace(NSRange(location: 0, length: 0), with: " ")
        }
    }
    defer { document.removeContentChangeObserver(observer) }
    var delivered: [EditorSyntaxProjection] = []
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/nested-edits.json"),
                                            initialText: document.text(in: NSRange(location: 0, length: document.length))) {
        delivered.append($0)
    }
    defer { controller.close() }
    try await waitForSyntax { controller.projection.kind(at: 2) == .property }
    delivered.removeAll()

    document.replace(NSRange(location: 0, length: 0), with: " ")
    #expect(document.contentVersion == 2)
    #expect(delivered.count == 1)
    #expect(delivered[0].kind(at: 4) == .property)
    #expect(delivered[0].kind(at: 2) == nil)
    try await waitForSyntax { !controller.hasPendingSyntaxWork }
    #expect(controller.projection.kind(at: 4) == .property)
}

@Test @MainActor func editorSyntaxFollowsUnicodeUndoRedoAndIME() async throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "{\r\n  \"name\": 1\r\n}")
    var projection = EditorSyntaxProjection.empty
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/test.json"),
                                            initialText: document.text(in: NSRange(location: 0, length: document.length))) {
        projection = $0
    }
    defer { controller.close() }
    try await waitForSyntax { projection.kind(at: 4) == .property }
    let editor = TerminalFileEditor(document: document, path: "/tmp/test.json")
    editor.selection.set(0)
    editor.setMarkedText("😀", selectedRange: NSRange(location: 2, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await waitForSyntax { projection.kind(at: 5) == .property }
    document.undo()
    try await waitForSyntax { projection.kind(at: 4) == .property }
    document.redo()
    try await waitForSyntax { projection.kind(at: 5) == .property }
    #expect(document.text(in: NSRange(location: 0, length: document.length)).hasPrefix("é{\n"))
}

@Test @MainActor func editorSyntaxSuppressesStaleResultsAndFallsBack() async throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "{\"x\": 1}")
    var projection = EditorSyntaxProjection.empty
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/test.json"),
                                            initialText: "{\"x\": 1}") { projection = $0 }
    defer { controller.close() }
    document.replace(NSRange(location: 2, length: 1), with: "😀")
    document.replace(NSRange(location: 2, length: 2), with: "updated")
    #expect(projection.highlights.isEmpty)
    try await waitForSyntax { projection.kind(at: 2) == .property }
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "{\"updated\": 1}")

    let unsupported = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/test.unknown"),
                                              initialText: "{\"updated\": 1}") { _ in }
    #expect(unsupported.projection.highlights.isEmpty)
    unsupported.close()

    let large = String(repeating: " ", count: EditorSyntaxController.maximumFileSize + 1)
    let oversized = EditorSyntaxController(document: EditorDocuments.make(text: large),
                                            url: URL(fileURLWithPath: "/tmp/test.json"), initialText: large) { _ in }
    #expect(oversized.projection.highlights.isEmpty)
    oversized.close()
    #expect(TerminalTheme.syntaxColor(for: .property) != TerminalTheme.syntaxColor(for: .number))
}

@Test @MainActor func editorSyntaxStartsForNewFileAndRecoversAfterOversizedOpenShrinks() async throws {
    let newFile = EditorDocuments.make(text: "")
    var newProjection = EditorSyntaxProjection.empty
    let newController = EditorSyntaxController(document: newFile, url: URL(fileURLWithPath: "/tmp/new.json"),
                                               initialText: "") { newProjection = $0 }
    defer { newController.close() }
    newFile.replace(NSRange(location: 0, length: 0), with: "{\"key\": true}")
    try await waitForSyntax { newProjection.kind(at: 1) == .property }

    let large = String(repeating: " ", count: EditorSyntaxController.maximumFileSize + 1)
    let document = EditorDocuments.make(text: large)
    var projection = EditorSyntaxProjection.empty
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/large.json"),
                                            initialText: large) { projection = $0 }
    defer { controller.close() }
    #expect(projection.highlights.isEmpty)
    document.replace(NSRange(location: 0, length: document.length), with: "{\"ok\": 1}")
    try await waitForSyntax { projection.kind(at: 1) == .property }
}

@Test @MainActor func editorSyntaxDropsOversizedSessionAndRebuildsAfterShrink() async throws {
    let document = EditorDocuments.make(text: "{\"key\": 1}")
    var projection = EditorSyntaxProjection.empty
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/growing.json"),
                                            initialText: "{\"key\": 1}") { projection = $0 }
    defer { controller.close() }
    try await waitForSyntax { controller.hasEditingSession && projection.kind(at: 1) == .property }

    // UTF-16 length stays under the cap while UTF-8 bytes exceed it.
    let oversized = String(repeating: "😀", count: EditorSyntaxController.maximumFileSize / 4 + 1)
    document.replace(NSRange(location: 0, length: document.length), with: oversized)
    #expect(document.length < EditorSyntaxController.maximumFileSize)
    #expect(!controller.hasEditingSession)
    #expect(!controller.hasPendingSyntaxWork)
    #expect(projection.highlights.isEmpty)
    for _ in 0..<20 {
        document.replace(NSRange(location: document.length, length: 0), with: "x")
        #expect(!controller.hasEditingSession)
        #expect(!controller.hasPendingSyntaxWork)
    }

    document.replace(NSRange(location: 0, length: document.length), with: "{\"after\": 2}")
    try await waitForSyntax { controller.hasEditingSession && projection.kind(at: 1) == .property }
    #expect(projection.kind(at: 8) == nil)
}

@Test @MainActor func editorSyntaxRecoveryUsesCurrentVersionAfterNestedObserverEdit() async throws {
    let oversized = String(repeating: " ", count: EditorSyntaxController.maximumFileSize + 1)
    let document = EditorDocuments.make(text: oversized)
    let observer = document.addContentChangeObserver { change in
        if change.version == 1 {
            document.replace(NSRange(location: 2, length: 0), with: "😀")
        }
    }
    defer { document.removeContentChangeObserver(observer) }
    var projection = EditorSyntaxProjection.empty
    let controller = EditorSyntaxController(document: document, url: URL(fileURLWithPath: "/tmp/nested.json"),
                                            initialText: oversized) { projection = $0 }
    defer { controller.close() }

    document.replace(NSRange(location: 0, length: document.length), with: "{\"key\": 1}")
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "{\"😀key\": 1}")
    try await waitForSyntax { controller.hasEditingSession && projection.kind(at: 4) == .property }
    // The colon follows the property at UTF-16 offset 8. A duplicated emoji
    // delta would move the parser's property span over that colon.
    #expect(projection.kind(at: 8) == nil)
    #expect(!controller.hasPendingSyntaxWork)
}

@Test @MainActor func terminalEditorDrawUsesSyntaxColorsWithSelectionPrecedence() async throws {
    _ = NSApplication.shared
    let source = "{\"key\": 1}"
    let editor = TerminalFileEditor(document: EditorDocuments.make(text: source), path: "/tmp/colors.json")
    editor.frame = NSRect(x: 0, y: 0, width: 300, height: 130)
    let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    func textAreaPixels() throws -> [NSColor?] {
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        let lower = Int(Double(bitmap.pixelsHigh) * 0.10)
        let upper = Int(Double(bitmap.pixelsHigh) * 0.80)
        return (lower..<upper).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in bitmap.colorAt(x: x, y: y) }
        }
    }
    let plainPixels = try textAreaPixels()
    editor.startSyntax(initialText: source)
    defer { editor.stopSyntax() }
    try await waitForSyntax {
        editor.foregroundColor(for: 1, selected: false) == TerminalTheme.syntaxColor(for: .property)
    }
    #expect(editor.foregroundColor(for: 0, selected: false) == TerminalTheme.accent)
    #expect(editor.foregroundColor(for: 1, selected: true) == TerminalTheme.contrastText)
    #expect(try textAreaPixels() != plainPixels)
    editor.document.replace(NSRange(location: 2, length: 0), with: "a")
    #expect(editor.foregroundColor(for: 2, selected: false) == TerminalTheme.syntaxColor(for: .property))
    #expect(editor.foregroundColor(for: 2, selected: true) == TerminalTheme.contrastText)
    // Composition retains its marked range, which draw() underlines separately
    // from the foreground-color decision.
    editor.selection.set(editor.document.length)
    editor.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.markedRange().location != NSNotFound)
    #expect(editor.markedRange().length == 1)
}

@Test @MainActor func coordinatorInstallsSyntaxForOpenedJSON() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("sample.json")
    try Data("{\"key\": 1}".utf8).write(to: url)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileEditorCoordinator()
    coordinator.present(url: url, window: window)
    try await waitForSyntax { !coordinator.isBusy }
    let editor = try #require(pane.subviews.compactMap { $0 as? TerminalFileEditor }.first)
    try await waitForSyntax {
        editor.foregroundColor(for: 1, selected: false) == TerminalTheme.syntaxColor(for: .property)
    }
    coordinator.requestClose()
}
