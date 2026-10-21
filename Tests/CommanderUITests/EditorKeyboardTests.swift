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

@Test @MainActor func editorMultiCaretShortcutsEditAndEscape() throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "foo\nfoo\nfoo")
    let editor = TerminalFileEditor(document: document, path: "/tmp/multicaret.txt")
    editor.selection.set(1)
    let down = String(NSEvent.SpecialKey.downArrow.unicodeScalar)
    editor.keyDown(with: try editorKey(down, code: 125, modifiers: [.command, .option]))
    #expect(editor.selection.caretCount == 2)
    editor.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "fXoo\nfXoo\nfoo")
    editor.keyDown(with: try editorKey("\u{1b}", code: 53, modifiers: []))
    #expect(editor.selection.caretCount == 1)

}

@Test @MainActor func editorOptionShiftClicksToggleCarets() throws {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "abc\nabc")
    let editor = TerminalFileEditor(document: document, path: "/tmp/clicks.txt")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = editor
    func click(row: Int, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        let point = editor.convert(NSPoint(x: 2 + TerminalTheme.cellAdvance,
            y: CGFloat(row + 1) * TerminalTheme.lineHeight + 4), to: nil)
        return try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    editor.mouseDown(with: try click(row: 0, modifiers: []))
    #expect(editor.selection.caret == 1)
    editor.mouseDown(with: try click(row: 1, modifiers: [.option, .shift]))
    #expect(editor.selection.caretCount == 2)
    #expect(editor.selection.carets.map(\.caret).sorted() == [1, 5])
    editor.mouseDown(with: try click(row: 0, modifiers: [.option, .shift]))
    #expect(editor.selection.caretCount == 1)
    #expect(editor.selection.caret == 5)
}

@Test @MainActor func editorArrowCommandsKeepCaretGroupAtEdges() {
    _ = NSApplication.shared
    let document = EditorDocuments.make(text: "aa\nbb\ncc\ndd")
    let editor = TerminalFileEditor(document: document, path: "/tmp/edges.txt")
    editor.selection.set(1)
    #expect(editor.selection.toggleCaret(at: 4))
    #expect(editor.selection.toggleCaret(at: 7))

    editor.doCommand(by: NSSelectorFromString("moveUp:"))
    #expect(editor.selection.carets.map(\.caret).sorted() == [1, 4, 7])
    editor.doCommand(by: NSSelectorFromString("moveDown:"))
    #expect(editor.selection.carets.map(\.caret).sorted() == [4, 7, 10])
    editor.doCommand(by: NSSelectorFromString("moveDown:"))
    #expect(editor.selection.carets.map(\.caret).sorted() == [4, 7, 10])
    #expect(editor.selection.caretCount == 3)
}
