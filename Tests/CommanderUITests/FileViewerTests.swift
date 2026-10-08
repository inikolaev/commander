import AppKit
import Foundation
import Testing
import FileManagerCore
import SyntaxCore
@testable import CommanderUI

@Test @MainActor func viewerDisplaysFilePagesAndRestoresFocusOnEscape() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try (1...100).map { "Line \($0): read-only viewer" }.joined(separator: "\n").write(to: url, atomically: false, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileViewerCoordinator()
    var closed = false
    coordinator.onClose = { closed = true }
    coordinator.present(url: url, window: window)
    #expect(coordinator.view == nil)
    #expect(window.firstResponder === pane)
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    #expect(viewer.page?.lines.first?.text == "Line 1: read-only viewer")
    #expect(window.firstResponder === viewer)
    coordinator.request(.end)
    for _ in 0..<200 {
        if viewer.page?.lines.last?.text == "Line 100: read-only viewer" { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.lines.last?.text == "Line 100: read-only viewer")
    if let output = ProcessInfo.processInfo.environment["COMMANDER_VIEWER_RENDER_PATH"] {
        let bitmap = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
    let f4 = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 118))
    viewer.keyDown(with: f4)
    for _ in 0..<200 {
        if viewer.page?.mode == .hex { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.mode == .hex)
    #expect(viewer.page?.lines.first?.text.contains(": ") == true)
    if let output = ProcessInfo.processInfo.environment["COMMANDER_HEX_RENDER_PATH"] {
        let bitmap = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
    viewer.keyDown(with: f4)
    for _ in 0..<200 {
        if viewer.page?.mode == .text { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.mode == .text)
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
    viewer.keyDown(with: escape)
    #expect(closed)
    #expect(coordinator.view == nil)
    #expect(window.firstResponder === pane)
}

@Test @MainActor func failedViewerOpenKeepsPanesVisibleAndRestoresFocus() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileViewerCoordinator()
    var closed = false
    coordinator.onClose = { closed = true }
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    coordinator.present(url: missing, window: window)
    #expect(coordinator.view == nil)
    for _ in 0..<200 {
        #expect(coordinator.view == nil)
        if pane.subviews.contains(where: { $0 is TerminalOperationDialog }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let dialog = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    #expect(!pane.subviews.contains(where: { $0 is TerminalFileViewer }))
    dialog.onDismiss?()
    #expect(closed)
    #expect(window.firstResponder === pane)
    #expect(pane.subviews.isEmpty)
}

@Test @MainActor func closingPendingViewerDoesNotPresentItLater() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("hello".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: url, window: window)
    coordinator.close()
    try await Task.sleep(for: .milliseconds(100))
    #expect(coordinator.view == nil)
    #expect(pane.subviews.isEmpty)
}

@Test @MainActor func viewerMouseSelectionCopiesDisplayedText() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try "abcdefghijklm\nsecond line\nthird".write(to: url, atomically: false, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 10)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let viewer = TerminalFileViewer(path: url.path)
    window.contentView = viewer
    viewer.update(page)
    let cell = ("a" as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
    func mouse(_ type: NSEvent.EventType, row: Int, column: Int) throws -> NSEvent {
        let point = viewer.convert(NSPoint(x: 1 + CGFloat(column) * cell,
            y: CGFloat(row + 1) * TerminalTheme.lineHeight + 4), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, column: 2))
    viewer.mouseDragged(with: try mouse(.leftMouseDragged, row: 1, column: 6))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 1, column: 6))
    #expect(window.firstResponder === viewer)
    #expect(viewer.selectedText == "cdefghijklm\nsecond")
    let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    viewer.keyDown(with: copy)
    #expect(NSPasteboard.general.string(forType: .string) == viewer.selectedText)

    // Backward drags produce the same ordered text, and unchanged refreshes retain selection.
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 1, column: 6))
    viewer.mouseDragged(with: try mouse(.leftMouseDragged, row: 0, column: 2))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, column: 2))
    viewer.update(page)
    #expect(viewer.selectedText == "cdefghijklm\nsecond")
    #expect(NSApp.sendAction(#selector(TerminalFileViewer.copy(_:)), to: viewer, from: nil))
    #expect(NSPasteboard.general.string(forType: .string) == viewer.selectedText)

    // Clicking clears selection; copying nothing leaves the clipboard intact.
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, column: 2))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, column: 2))
    #expect(viewer.selectedText.isEmpty)
    viewer.keyDown(with: copy)
    #expect(NSPasteboard.general.string(forType: .string) == "cdefghijklm\nsecond")

    viewer.wrapsText = false
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    viewer.keyDown(with: right)
    #expect(viewer.horizontalOffset == 1)
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, column: 0))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, column: 3))
    #expect(viewer.selectedText == "bcd")

    let controlRight = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    viewer.keyDown(with: controlRight)
    #expect(viewer.horizontalOffset == 21)
    viewer.update(try await document.page(.scroll(1), rows: 10))
    #expect(viewer.selectedText.isEmpty)
}

@Test @MainActor func viewerSelectionPreservesComposedCharactersAndEmptyLines() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = "A😀e\u{301}Z"
    try (first + "\n\nlast").write(to: url, atomically: false, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 10)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let viewer = TerminalFileViewer(path: url.path)
    window.contentView = viewer
    viewer.update(page)
    func mouse(_ type: NSEvent.EventType, row: Int, prefix: String) throws -> NSEvent {
        let width = (prefix as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
        let point = viewer.convert(NSPoint(x: 1 + width, y: CGFloat(row + 1) * TerminalTheme.lineHeight + 4), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, prefix: "A"))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, prefix: "A😀e\u{301}"))
    #expect(viewer.selectedText == "😀e\u{301}")
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, prefix: "A"))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 2, prefix: "la"))
    #expect(viewer.selectedText == "😀e\u{301}Z\n\nla")
    // Render with an active selection to exercise highlighting too.
    let bitmap = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
    viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
    viewer.update(try await document.page(rows: 10, mode: .hex))
    #expect(viewer.selectedText.isEmpty)
}


private struct TestSyntaxHighlighter: SyntaxHighlighter {
    let isActive = true
    let spans: [SyntaxHighlightSpan]

    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] {
        spans.filter {
            $0.byteRange.lowerBound < byteRange.upperBound
                && $0.byteRange.upperBound > byteRange.lowerBound
        }
    }
}

@Test func viewerSyntaxProjectionMergesSourceAndSpansSequentially() async throws {
    let source = "\t\"é\": true\n"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(source.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 1, includeSourceText: true)
    let bytes = Array(source.utf8)
    let quoteStart = try #require(bytes.firstIndex(of: 34))
    let colon = try #require(bytes.firstIndex(of: 58))
    let trueStart = colon + 2
    let highlighter = TestSyntaxHighlighter(spans: [
        SyntaxHighlightSpan(byteRange: quoteStart..<colon, kind: .property),
        SyntaxHighlightSpan(byteRange: trueStart..<(trueStart + 4), kind: .constant),
    ])

    let projection = ViewerSyntaxProjection.make(page: page, highlighter: highlighter)
    let line = try #require(projection.lines.first)
    #expect(line == [
        ViewerDisplayHighlight(range: 4..<7, kind: .property),
        ViewerDisplayHighlight(range: 9..<13, kind: .constant),
    ])
}

@Test func viewerSyntaxProjectionHandlesManySpansOnOneLogicalLine() async throws {
    let fields = (0..<5_000).map { "\"k\($0)\":\($0)" }
    let source = "{" + fields.joined(separator: ",") + "}\n"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(source.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 1, includeSourceText: true)
    var spans: [SyntaxHighlightSpan] = []
    var cursor = 1
    for index in 0..<5_000 {
        let key = "\"k\(index)\""
        let keyEnd = cursor + key.utf8.count
        spans.append(SyntaxHighlightSpan(byteRange: cursor..<keyEnd, kind: .property))
        cursor = keyEnd + 1
        let value = String(index)
        let valueEnd = cursor + value.utf8.count
        spans.append(SyntaxHighlightSpan(byteRange: cursor..<valueEnd, kind: .number))
        cursor = valueEnd + (index == 4_999 ? 0 : 1)
    }

    let projection = ViewerSyntaxProjection.make(
        page: page,
        highlighter: TestSyntaxHighlighter(spans: spans)
    )
    #expect(projection.lines.count == 1)
    #expect(projection.lines[0].count == 10_000)
    #expect(projection.lines[0].first?.range == 1..<5)
    #expect(projection.lines[0].last?.kind == .number)
}
