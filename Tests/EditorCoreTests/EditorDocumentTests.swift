import Foundation
import Testing
import EditorCore

@Test func editsUpdateLinesAndUndoRestoresSavedRevision() {
    let doc = EditorDocuments.make(text: "one\ntwo\nthree")
    let cursor = EditorSelection(document: doc)
    cursor.set(4)
    cursor.replace(with: "new\n")
    #expect(doc.lineCount == 4)
    #expect(doc.text(in: doc.lineRange(2)) == "two")
    #expect(doc.lineIndex(at: 8) == 2)
    doc.markSaved()
    cursor.select(NSRange(location: 2, length: 8))
    cursor.replace(with: "")
    #expect(doc.isModified)
    #expect(doc.lineCount == 2)
    cursor.undo()
    #expect(!doc.isModified)
    #expect(doc.lineCount == 4)
    cursor.undo()
    #expect(doc.isModified)
    #expect(doc.text(in: NSRange(location: 0, length: doc.length)) == "one\ntwo\nthree")
    cursor.redo()
    #expect(!doc.isModified)
}

@Test func unicodeCursorSelectionAndDeletion() {
    let doc = EditorDocuments.make(text: "a👨‍👩‍👧‍👦e\u{301}\nshort\n")
    let cursor = EditorSelection(document: doc)
    cursor.moveHorizontal(1, extending: false)
    cursor.moveHorizontal(1, extending: false)
    #expect(cursor.column == 2)
    cursor.delete(backward: true)
    #expect(doc.text(in: doc.lineRange(0)) == "ae\u{301}")
    cursor.undo()
    #expect(cursor.column == 2)
    cursor.moveHorizontal(1, extending: false)
    cursor.delete(backward: true)
    #expect(doc.text(in: doc.lineRange(0)) == "a👨‍👩‍👧‍👦")
    cursor.set(doc.length)
    cursor.delete(backward: true)
    #expect(doc.lineCount == 2)
}

@Test func verticalNavigationRetainsColumnAcrossShortLines() {
    let doc = EditorDocuments.make(text: "abcdef\nx\nuvwxyz")
    let cursor = EditorSelection(document: doc)
    cursor.set(5)
    cursor.moveVertical(1, extending: true)
    #expect(cursor.column == 1)
    cursor.moveVertical(1, extending: true)
    #expect(cursor.column == 5)
    #expect(cursor.anchor == 5)
}

@Test func compositionIsOneUndoStep() {
    let doc = EditorDocuments.make(text: "before")
    doc.beginUndoGroup()
    doc.replace(NSRange(location: 6, length: 0), with: "e")
    doc.replace(NSRange(location: 6, length: 1), with: "é")
    doc.endUndoGroup()
    doc.undo()
    #expect(doc.text(in: NSRange(location: 0, length: doc.length)) == "before")
    doc.redo()
    #expect(doc.text(in: NSRange(location: 0, length: doc.length)) == "beforeé")
}

@Test func contentChangesUsePreEditUTF16RangesAndNormalizedText() {
    let doc = EditorDocuments.make(text: "a😀b")
    var events: [EditorContentChange] = []
    var observedTexts: [String] = []
    let id = doc.addContentChangeObserver { change in
        events.append(change)
        observedTexts.append(doc.text(in: NSRange(location: 0, length: doc.length)))
        #expect(doc.contentVersion == change.version)
    }

    #expect(doc.contentVersion == 0)
    doc.replace(NSRange(location: 1, length: 2), with: "x\r\ny\rz")
    #expect(events == [EditorContentChange(changes: [
        EditorContentDelta(range: NSRange(location: 1, length: 2), insertedText: "x\ny\nz"),
    ], version: 1)])
    #expect(observedTexts == ["ax\ny\nzb"])

    // Equality is checked after newline normalization.
    doc.replace(NSRange(location: 1, length: 5), with: "x\r\ny\rz")
    #expect(doc.contentVersion == 1)
    #expect(events.count == 1)

    doc.markSaved()
    #expect(!doc.isModified)
    doc.undo()
    #expect(doc.isModified)
    #expect(doc.contentVersion == 2)
    #expect(events[1] == EditorContentChange(changes: [
        EditorContentDelta(range: NSRange(location: 1, length: 5), insertedText: "😀"),
    ], version: 2))
    doc.redo()
    #expect(!doc.isModified)
    #expect(doc.contentVersion == 3)
    #expect(events[2] == EditorContentChange(changes: [
        EditorContentDelta(range: NSRange(location: 1, length: 2), insertedText: "x\ny\nz"),
    ], version: 3))

    doc.removeContentChangeObserver(id)
    doc.replace(NSRange(location: 0, length: 1), with: "A")
    #expect(doc.contentVersion == 4)
    #expect(events.count == 3)
}

@Test func groupedCompositionPublishesOrderedUndoRedoDeltas() {
    let doc = EditorDocuments.make(text: "before")
    var changes: [EditorContentChange] = []
    doc.addContentChangeObserver { changes.append($0) }

    doc.beginUndoGroup()
    doc.replace(NSRange(location: 6, length: 0), with: "e")
    doc.replace(NSRange(location: 6, length: 1), with: "é")
    doc.replace(NSRange(location: 6, length: 1), with: "é") // No mutation.
    doc.endUndoGroup()
    #expect(changes == [
        EditorContentChange(changes: [
            EditorContentDelta(range: NSRange(location: 6, length: 0), insertedText: "e"),
        ], version: 1),
        EditorContentChange(changes: [
            EditorContentDelta(range: NSRange(location: 6, length: 1), insertedText: "é"),
        ], version: 2),
    ])
    #expect(doc.contentVersion == 2)

    doc.undo()
    #expect(changes[2] == EditorContentChange(changes: [
        EditorContentDelta(range: NSRange(location: 6, length: 1), insertedText: "e"),
        EditorContentDelta(range: NSRange(location: 6, length: 1), insertedText: ""),
    ], version: 4))
    #expect(doc.text(in: NSRange(location: 0, length: doc.length)) == "before")
    #expect(doc.contentVersion == 4)

    doc.redo()
    #expect(changes[3] == EditorContentChange(changes: [
        EditorContentDelta(range: NSRange(location: 6, length: 0), insertedText: "e"),
        EditorContentDelta(range: NSRange(location: 6, length: 1), insertedText: "é"),
    ], version: 6))
    #expect(doc.text(in: NSRange(location: 0, length: doc.length)) == "beforeé")
    #expect(doc.contentVersion == 6)
}

@Test func undoRedoObserversSeeFinalRevisionAndHistory() {
    let doc = EditorDocuments.make(text: "")
    doc.replace(NSRange(location: 0, length: 0), with: "a")
    doc.markSaved()
    doc.replace(NSRange(location: 1, length: 0), with: "b")

    var states: [(version: Int, modified: Bool, canUndo: Bool, canRedo: Bool)] = []
    doc.addContentChangeObserver { event in
        states.append((event.version, doc.isModified, doc.canUndo, doc.canRedo))
    }
    doc.undo()
    doc.redo()

    #expect(states.count == 2)
    #expect(states[0].version == 3)
    #expect(!states[0].modified)
    #expect(states[0].canUndo)
    #expect(states[0].canRedo)
    #expect(states[1].version == 4)
    #expect(states[1].modified)
    #expect(states[1].canUndo)
    #expect(!states[1].canRedo)
}

@Test func nestedObserverEditPreservesHistoryAndEventOrder() {
    let doc = EditorDocuments.make(text: "")
    doc.replace(NSRange(location: 0, length: 0), with: "a")
    doc.markSaved()
    doc.replace(NSRange(location: 1, length: 0), with: "b")

    var firstObserverVersions: [Int] = []
    var secondObserverVersions: [Int] = []
    doc.addContentChangeObserver { event in
        firstObserverVersions.append(event.version)
        if event.version == 3 {
            #expect(!doc.isModified)
            #expect(doc.canRedo)
            doc.replace(NSRange(location: doc.length, length: 0), with: "c")
            #expect(doc.isModified)
            #expect(!doc.canRedo)
        }
    }
    doc.addContentChangeObserver { event in
        secondObserverVersions.append(event.version)
    }

    doc.undo()
    #expect(firstObserverVersions == [3, 4])
    #expect(secondObserverVersions == [3, 4])
    #expect(doc.text(in: NSRange(location: 0, length: doc.length)) == "ac")
    #expect(doc.contentVersion == 4)
    #expect(doc.isModified)
    #expect(!doc.canRedo)
    doc.undo()
    #expect(doc.text(in: NSRange(location: 0, length: doc.length)) == "a")
    #expect(!doc.isModified)
}

@Test func lineIndexMatchesReferenceAfterManyEdits() {
    let doc = EditorDocuments.make(text: "")
    var reference = ""
    var seed: UInt64 = 7
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    for _ in 0..<700 {
        let length = reference.utf16.count
        let start = next(length + 1)
        let count = next(length - start + 1)
        let text = ["a", "\n", "ab\ncd", "", "\n\n"][next(5)]
        let range = NSRange(location: start, length: count)
        doc.replace(range, with: text)
        reference = (reference as NSString).replacingCharacters(in: range, with: text)
        let lines = reference.components(separatedBy: "\n")
        #expect(doc.lineCount == lines.count)
        for (index, line) in lines.enumerated() {
            #expect(doc.text(in: doc.lineRange(index)) == line)
            #expect(doc.lineIndex(at: doc.lineRange(index).location) == index)
        }
    }
}
