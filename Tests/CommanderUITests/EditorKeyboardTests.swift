import AppKit
import Testing
import EditorCore
@testable import CommanderUI

@MainActor private func editorKey(_ characters: String, code: UInt16,
                                  modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}

@Test @MainActor func editorCommandYDeletesLineAndSupportsUndoRedo() throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "first\nsecond\nthird")
    let editor = TerminalFileEditor(document: document, path: "/tmp/keys.txt")
    editor.selection.set(8)
    editor.keyDown(with: try editorKey("y", code: 16, modifiers: .command))
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "first\nthird")
    #expect(editor.selection.range == NSRange(location: 8, length: 0))
    editor.keyDown(with: try editorKey("z", code: 6, modifiers: .command))
    #expect(!document.isModified)
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "first\nsecond\nthird")
    editor.keyDown(with: try editorKey("Z", code: 6, modifiers: [.command, .shift]))
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "first\nthird")
}

@Test @MainActor func editorModifiedArrowsNavigateAndExtendSelection() throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "above\none  two three\nbelow")
    let editor = TerminalFileEditor(document: document, path: "/tmp/keys.txt")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = editor
    window.makeFirstResponder(editor)
    let start = document.lineRange(1).location
    let end = NSMaxRange(document.lineRange(1))
    let left = String(NSEvent.SpecialKey.leftArrow.unicodeScalar)
    let right = String(NSEvent.SpecialKey.rightArrow.unicodeScalar)

    editor.selection.set(start + 6)
    editor.keyDown(with: try editorKey(left, code: 123, modifiers: .command))
    #expect(editor.selection.range == NSRange(location: start, length: 0))
    editor.keyDown(with: try editorKey(right, code: 124, modifiers: [.command, .shift]))
    #expect(editor.selection.range == document.lineRange(1))
    #expect(editor.selection.anchor == start)
    editor.keyDown(with: try editorKey(right, code: 124, modifiers: .command))
    #expect(editor.selection.range == NSRange(location: end, length: 0))
    editor.keyDown(with: try editorKey(left, code: 123, modifiers: [.command, .shift]))
    #expect(editor.selection.range == document.lineRange(1))
    #expect(editor.selection.anchor == end)

    editor.selection.set(start)
    editor.keyDown(with: try editorKey(right, code: 124, modifiers: .option))
    #expect(editor.selection.range == NSRange(location: start + 3, length: 0))
    editor.keyDown(with: try editorKey(right, code: 124, modifiers: [.option, .shift]))
    #expect(editor.selection.range == NSRange(location: start + 3, length: 5))
    #expect(editor.selection.anchor == start + 3)
    editor.keyDown(with: try editorKey(left, code: 123, modifiers: .option))
    #expect(editor.selection.range == NSRange(location: start + 5, length: 0))
    editor.keyDown(with: try editorKey(left, code: 123, modifiers: [.option, .shift]))
    #expect(editor.selection.range == NSRange(location: start, length: 5))
    #expect(editor.selection.anchor == start + 5)
    #expect(!document.isModified)
}

@Test @MainActor func editorWordMovementHandlesUnicodeBlankLinesAndDocumentEdges() {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "e\u{301}lan, 👩‍💻\n\nlast")
    let editor = TerminalFileEditor(document: document, path: "/tmp/words.txt")
    let right = NSSelectorFromString("moveWordForward:")
    let left = NSSelectorFromString("moveWordBackward:")
    for offset in [5, 12, 13, 18, 18] {
        editor.doCommand(by: right)
        #expect(editor.selection.caret == offset)
        #expect(editor.selection.anchor == offset)
    }
    for offset in [14, 13, 7, 0, 0] {
        editor.doCommand(by: left)
        #expect(editor.selection.caret == offset)
        #expect(editor.selection.anchor == offset)
    }
    #expect(!document.isModified)

    let empty = TerminalFileEditor(document: EditorDocuments.make(text: ""), path: "/tmp/empty.txt")
    empty.doCommand(by: right)
    empty.doCommand(by: left)
    #expect(empty.selection.range == NSRange(location: 0, length: 0))
    #expect(!empty.document.isModified)
}

@Test @MainActor func editorDeleteLineCommitsCompositionBeforeSeparateUndoableDeletion() throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "first\nlast")
    let editor = TerminalFileEditor(document: document, path: "/tmp/composition.txt")
    editor.setMarkedText("é", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    editor.keyDown(with: try editorKey("y", code: 16, modifiers: .command))
    #expect(!editor.hasMarkedText())
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "last")
    editor.selection.undo()
    #expect(document.text(in: document.lineRange(0)) == "éfirst")
    editor.selection.undo()
    #expect(!document.isModified)
}
