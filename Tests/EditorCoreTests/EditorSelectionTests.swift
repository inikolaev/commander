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

@Test func multipleCaretsInsertDeleteAndUndoAsOneEdit() {
    let document = EditorDocuments.make(text: "cat\ncat\ncat")
    let selection = EditorSelection(document: document)
    selection.set(1)
    #expect(selection.toggleCaret(at: 5))
    #expect(selection.toggleCaret(at: 9))
    #expect(selection.caretCount == 3)
    selection.replace(with: "X")
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "cXat\ncXat\ncXat")
    #expect(selection.carets.map(\.caret).sorted() == [2, 7, 12])
    selection.delete(backward: true)
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "cat\ncat\ncat")
    selection.undo()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "cXat\ncXat\ncXat")
    #expect(selection.caretCount == 1)
    selection.undo()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "cat\ncat\ncat")
}

@Test func multipleSelectionsReplaceAndMergeOverlaps() {
    let document = EditorDocuments.make(text: "one two one")
    let selection = EditorSelection(document: document)
    selection.select(NSRange(location: 0, length: 3))
    #expect(selection.addSelection(NSRange(location: 8, length: 3)))
    #expect(!selection.addSelection(NSRange(location: 9, length: 2)))
    selection.replace(with: "ONE")
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "ONE two ONE")
    #expect(selection.caretCount == 2)
    #expect(selection.ranges.allSatisfy { $0.length == 0 })
    selection.clearAdditionalCarets()
    #expect(selection.caretCount == 1)
}

@Test func verticalCaretAdditionClampsOnShortLines() {
    let document = EditorDocuments.make(text: "abcdef\nx\nabcdef")
    let selection = EditorSelection(document: document)
    selection.set(5)
    selection.addCaretVertically(1)
    #expect(selection.caretCount == 2)
    #expect(selection.carets.map(\.caret).sorted() == [5, 8])
    selection.addCaretVertically(1)
    #expect(selection.carets.map(\.caret).sorted() == [5, 8, 10])
    #expect(!selection.toggleCaret(at: 8))
    #expect(selection.caretCount == 2)
}

@Test func multipleCaretsDistributeReplacementInDocumentOrder() {
    let document = EditorDocuments.make(text: "a\nb\nc")
    let selection = EditorSelection(document: document)
    selection.select(NSRange(location: 4, length: 1))
    #expect(selection.addSelection(NSRange(location: 0, length: 1)))
    #expect(selection.addSelection(NSRange(location: 2, length: 1)))
    selection.replace(with: ["one", "two", "three"])
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "one\ntwo\nthree")
    #expect(selection.carets.map(\.caret).sorted() == [3, 7, 13])
    selection.undo()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "a\nb\nc")
}

@Test func verticalMovementStopsWholeCaretGroupAtDocumentEdges() {
    let document = EditorDocuments.make(text: "aa\nbb\ncc\ndd")
    let selection = EditorSelection(document: document)
    selection.set(1)
    #expect(selection.toggleCaret(at: 4))
    #expect(selection.toggleCaret(at: 7))
    let original = selection.carets.map(\.caret).sorted()
    #expect(original == [1, 4, 7])

    #expect(selection.moveCaretsVertically(-1, extending: false) == 0)
    #expect(selection.carets.map(\.caret).sorted() == original)
    #expect(selection.caretCount == 3)
    #expect(selection.moveCaretsVertically(1, extending: false) == 1)
    #expect(selection.carets.map(\.caret).sorted() == [4, 7, 10])
    #expect(selection.moveCaretsVertically(1, extending: false) == 0)
    #expect(selection.carets.map(\.caret).sorted() == [4, 7, 10])
    #expect(selection.caretCount == 3)
    #expect(selection.moveCaretsVertically(-1, extending: false) == -1)
    #expect(selection.carets.map(\.caret).sorted() == original)
}

@Test func pageMovementClampsGroupWithoutCollapsingCarets() {
    let document = EditorDocuments.make(text: "a\nb\nc\nd\ne")
    let selection = EditorSelection(document: document)
    selection.set(0)
    #expect(selection.toggleCaret(at: 2))
    #expect(selection.moveCaretsVertically(10, extending: false) == 3)
    #expect(selection.carets.map(\.line).sorted() == [3, 4])
    #expect(selection.moveCaretsVertically(-10, extending: false) == -3)
    #expect(selection.carets.map(\.line).sorted() == [0, 1])
}

@Test func caretsThatConvergeAfterDeletionBecomeOne() {
    let document = EditorDocuments.make(text: "ab")
    let selection = EditorSelection(document: document)
    selection.set(1)
    #expect(selection.toggleCaret(at: 2))
    selection.delete(backward: true)
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "")
    #expect(selection.caretCount == 1)
    #expect(selection.caret == 0)
    selection.replace(with: "x")
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == "x")
}

@Test func caretsThatConvergeOnShortLineBecomeOne() {
    let document = EditorDocuments.make(text: "abcd\nx")
    let selection = EditorSelection(document: document)
    selection.set(2)
    #expect(selection.toggleCaret(at: 3))
    #expect(selection.moveCaretsVertically(1, extending: false) == 1)
    #expect(selection.caretCount == 1)
    #expect(selection.caret == document.length)
}
