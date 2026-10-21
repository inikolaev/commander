import Foundation
import Testing
import EditorCore

@Test(arguments: [
    ("one\ntwo\nthree", 1, "two\nthree", 1),
    ("one\ntwo\nthree", 5, "one\nthree", 5),
    ("one\ntwo\nthree", 10, "one\ntwo", 6),
    ("one\n\nthree", 4, "one\nthree", 4),
    ("one\n", 4, "one", 0),
    ("one", 2, "", 0),
    ("", 0, "", 0),
    ("abc\nx\nlast", 2, "x\nlast", 1),
    ("abc\n👩‍💻e\u{301}z", 2, "👩‍💻e\u{301}z", 7),
])
func deleteLineHandlesDocumentEdgesAndPreservesGraphemeColumn(
    original: String, caret: Int, expected: String, expectedCaret: Int
) {
    let document = EditorDocuments.make(text: original)
    let selection = EditorSelection(document: document)
    selection.set(caret)
    selection.deleteLine()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == expected)
    #expect(selection.range == NSRange(location: expectedCaret, length: 0))
    #expect(document.isModified == (original != expected))
    #expect(document.canUndo == (original != expected))
    selection.undo()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == original)
    #expect(!document.isModified)
    #expect(!document.canUndo)
    selection.redo()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == expected)
}

@Test func deleteLineUsesCaretLineWhenTextIsSelected() {
    let document = EditorDocuments.make(text: "first\nsecond\nthird")
    let selection = EditorSelection(document: document)
    selection.set(2)
    selection.set(8, extending: true)
    selection.deleteLine()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "first\nthird")
    #expect(selection.range == NSRange(location: 8, length: 0))
    selection.undo()
    selection.set(8)
    selection.set(2, extending: true)
    selection.deleteLine()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "second\nthird")
    #expect(selection.range == NSRange(location: 2, length: 0))
}
