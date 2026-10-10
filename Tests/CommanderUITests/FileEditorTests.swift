import AppKit
import Testing
import EditorCore
@testable import CommanderUI

@Test @MainActor func f4OpensEditorAndShiftF4CreatesFile() throws {
    _ = NSApplication.shared
    let pane = TerminalPaneView(name: "Test")
    var actions: [PaneInput] = []
    pane.onInput = { actions.append($0) }
    for flags: NSEvent.ModifierFlags in [[], [.shift]] {
        pane.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: String(NSEvent.SpecialKey.f4.unicodeScalar),
            charactersIgnoringModifiers: String(NSEvent.SpecialKey.f4.unicodeScalar), isARepeat: false, keyCode: 0)))
    }
    #expect(actions.count == 2)
    if case .createFile = actions.last {} else { Issue.record("Expected create file action") }
    #expect(TerminalKeyBar.command(number: 4, shift: true) == .createFile)
    if case .editFile = actions.first {} else { Issue.record("Expected edit action") }
    #expect(TerminalKeyBar().labels[4] == "Edit")
}

@Test @MainActor func editorTextInputCompositionAndRendering() throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "Hello, Commander!\nUnicode: Märkätilan 👩‍💻\n\tIndented text\n")
    let editor = TerminalFileEditor(document: document, path: "/tmp/example.txt")
    editor.frame = NSRect(x: 0, y: 0, width: 1080, height: 600)
    let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    editor.selection.set(document.length)
    editor.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!editor.hasMarkedText())
    #expect(document.text(in: document.lineRange(3)) == "é")
    editor.selection.undo()
    #expect(!document.isModified)
    editor.selection.redo()
    editor.selection.select(NSRange(location: 7, length: 9))
    editor.changed()
    if let output = ProcessInfo.processInfo.environment["COMMANDER_EDITOR_RENDER_PATH"] {
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}

@Test @MainActor func editorSaveCloseAndConflictKeepEditsSafe() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("test.txt")
    try Data("original".utf8).write(to: url)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileEditorCoordinator()
    var closed = false
    coordinator.onClose = { closed = true }
    coordinator.present(url: url, window: window)
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let editor = try #require(pane.subviews.compactMap { $0 as? TerminalFileEditor }.first)
    editor.insertText("new ", replacementRange: NSRange(location: NSNotFound, length: 0))
    coordinator.requestClose()
    let prompt = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    #expect(prompt.focusedControl == 2)
    prompt.onChoice?(2)
    #expect(!closed)
    #expect(window.firstResponder === editor)
    coordinator.requestClose()
    try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first).onChoice?(0)
    for _ in 0..<200 {
        if closed { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(closed)
    #expect(try String(contentsOf: url, encoding: .utf8) == "new original")
    #expect(window.firstResponder === pane)

    closed = false
    coordinator.present(url: url, window: window)
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let next = try #require(pane.subviews.compactMap { $0 as? TerminalFileEditor }.first)
    next.insertText("unsaved ", replacementRange: NSRange(location: NSNotFound, length: 0))
    try Data("external".utf8).write(to: url)
    coordinator.save()
    for _ in 0..<200 {
        if let dialog = pane.subviews.compactMap({ $0 as? TerminalOperationDialog }).first,
            case .error = dialog.mode { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let error = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    guard case .error = error.mode else { Issue.record("Expected save conflict"); return }
    error.onDismiss?()
    #expect(next.document.isModified)
    #expect(!closed)
    #expect(window.firstResponder === next)
    #expect(try String(contentsOf: url, encoding: .utf8) == "external")
    coordinator.requestClose()
    try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first).onChoice?(1)
    #expect(closed)
}

@Test @MainActor func editorOpenErrorStaysOverPanes() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileEditorCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/missing"), window: window)
    for _ in 0..<200 {
        if let dialog = pane.subviews.compactMap({ $0 as? TerminalOperationDialog }).first,
            case .error = dialog.mode { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!pane.subviews.contains { $0 is TerminalFileEditor })
    let error = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    guard case .error = error.mode else { Issue.record("Expected open error"); return }
    error.onDismiss?()
    #expect(window.firstResponder === pane)
}

@Test @MainActor func editorPageNavigationScrollsViewportAndPreservesScreenRow() {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: (0..<100).map { "Line \($0)" }.joined(separator: "\n"))
    let editor = TerminalFileEditor(document: document, path: "/tmp/pages.txt")
    editor.frame = NSRect(x: 0, y: 0, width: 800, height: 216)
    let rows = editor.visibleRows
    editor.doCommand(by: NSSelectorFromString("pageDown:"))
    #expect(editor.topLine == rows)
    #expect(editor.selection.line == rows)
    editor.doCommand(by: NSSelectorFromString("pageUp:"))
    #expect(editor.topLine == 0)
    #expect(editor.selection.line == 0)

    editor.selection.set(document.lineRange(3).location + 2)
    editor.changed()
    editor.doCommand(by: NSSelectorFromString("pageDownAndModifySelection:"))
    #expect(editor.topLine == rows)
    #expect(editor.selection.line == rows + 3)
    #expect(editor.selection.column == 2)
    #expect(editor.selection.range.location == document.lineRange(3).location + 2)
    #expect(editor.selection.range.length > 0)
    for _ in 0..<20 { editor.doCommand(by: NSSelectorFromString("pageDown:")) }
    #expect(editor.selection.line == 99)
    #expect(editor.topLine == 100 - rows)
    for _ in 0..<20 { editor.doCommand(by: NSSelectorFromString("pageUp:")) }
    #expect(editor.selection.line == 0)
    #expect(editor.topLine == 0)
}

@Test @MainActor func editorAndViewerUseLastRowWhenTextFitsAboveFooter() {
    _ = NSApplication.shared
    let textHeight = ceil(("Mg" as NSString).size(withAttributes: [.font: TerminalTheme.font]).height)
    let height = 2 * TerminalTheme.lineHeight + 9 * TerminalTheme.lineHeight + textHeight
    let editor = TerminalFileEditor(document: EditorDocuments.make(text: "test"), path: "/tmp/test")
    let viewer = TerminalFileViewer(path: "/tmp/test")
    for view in [editor as NSView, viewer as NSView] {
        view.frame = NSRect(x: 0, y: 0, width: 800, height: height)
    }
    #expect(editor.visibleRows == 10)
    #expect(viewer.visibleRows == 10)
    editor.setFrameSize(NSSize(width: 800, height: height - 1))
    viewer.setFrameSize(NSSize(width: 800, height: height - 1))
    #expect(editor.visibleRows == 9)
    #expect(viewer.visibleRows == 9)
}

@Test @MainActor func newFilePromptCancelRetryAndEmptySave() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileEditorCoordinator()
    var closed = false
    coordinator.onClose = { closed = true }
    func dialog() throws -> TerminalOperationDialog {
        try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    }
    coordinator.presentNewFile(directory: root, window: window)
    try dialog().onCancel?()
    #expect(closed)
    #expect(!coordinator.isBusy)
    #expect(window.firstResponder === pane)
    closed = false
    coordinator.presentNewFile(directory: root, window: window)
    try dialog().onConfirm?("../invalid")
    for _ in 0..<200 {
        if let current = try? dialog(), case .error = current.mode { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let error = try dialog()
    guard case .error = error.mode else { Issue.record("Expected validation error"); return }
    error.onDismiss?()
    #expect(coordinator.isBusy)
    try dialog().onConfirm?("empty.txt")
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(pane.subviews.contains { $0 is TerminalFileEditor })
    let url = root.appendingPathComponent("empty.txt")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    coordinator.save()
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try Data(contentsOf: url).isEmpty)
    coordinator.requestClose()
    #expect(closed)
    #expect(window.firstResponder === pane)
}
