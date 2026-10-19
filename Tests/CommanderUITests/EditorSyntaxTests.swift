import AppKit
import EditorCore
import SyntaxCore
import Testing
@testable import CommanderUI

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
    #expect(projection.kind(at: 4) == nil) // changed property has no stale color
    #expect(projection.kind(at: 15) == .property) // following property shifted left
    document.undo()
    #expect(projection.kind(at: 16) == .property)
    try await waitForSyntax { projection.kind(at: 4) == .property && projection.kind(at: 16) == .property }
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "  {\"first\": 1, \"second\": 2}")
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
