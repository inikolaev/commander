import Foundation
internal import TextBuffer

/// One replacement within an edit operation. `range` uses UTF-16 coordinates
/// in the document immediately before this particular replacement.
public struct EditorContentDelta: Equatable {
    public let range: NSRange
    public let insertedText: String

    public init(range: NSRange, insertedText: String) {
        self.range = range
        self.insertedText = insertedText
    }
}

/// An applied replace, undo, or redo. Deltas are in application order;
/// `version` identifies the content after the entire operation.
public struct EditorContentChange: Equatable {
    public let changes: [EditorContentDelta]
    public let version: Int

    public init(changes: [EditorContentDelta], version: Int) {
        self.changes = changes
        self.version = version
    }
}

/// Editor coordinates are UTF-16 offsets. Ranges must end on grapheme boundaries.
/// No storage-library types cross this boundary.
public protocol EditorDocument: AnyObject {
    var length: Int { get }
    var lineCount: Int { get }
    /// Increases once per actual content mutation, including undo and redo.
    var contentVersion: Int { get }
    var isModified: Bool { get }
    var canUndo: Bool { get }
    var canRedo: Bool { get }
    func text(in range: NSRange) -> String
    func lineRange(_ index: Int) -> NSRange
    func lineIndex(at offset: Int) -> Int
    func replace(_ range: NSRange, with text: String)
    /// Calls observers after each replace, undo, or redo has finished updating
    /// content and history. Nested edits are delivered after the current event.
    /// Remove the returned ID when observation is no longer needed.
    @discardableResult func addContentChangeObserver(_ observer: @escaping (EditorContentChange) -> Void) -> UUID
    func removeContentChangeObserver(_ id: UUID)
    func beginUndoGroup()
    func endUndoGroup()
    @discardableResult func undo() -> NSRange?
    @discardableResult func redo() -> NSRange?
    func markSaved()
}

public enum EditorDocuments {
    public static func make(text: String) -> any EditorDocument {
        let trace = EditorLoadTrace()
        let normalized = normalizeNewlines(text)
        trace.checkpoint("normalize-on-document-create")
        return RopeDocument(text: normalized)
    }

    /// EditorFile guarantees LF-normalized text; do not scan it a second time.
    public static func make(file: EditorFile) -> any EditorDocument {
        RopeDocument(text: file.text, lineStarts: file.preparedLineStarts)
    }

    public static func normalizeNewlines(_ text: String) -> String {
        EditorTextPreparation.normalize(text)
    }
}

/// The only adapter that knows which third-party buffer we use.
/// A line-start index is updated from each replacement, never from a full-text
/// snapshot during drawing or navigation. Undo stores deltas, not whole files.
private final class RopeDocument: EditorDocument {
    private let buffer: RopeBuffer
    private var starts: [Int]
    private struct Change {
        let offset: Int
        let before: String
        let after: String
    }
    private struct Edit {
        var changes: [Change]
        let beforeRevision: Int
        var afterRevision: Int
    }
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private var pending: Edit?
    private var grouping = false
    private var revision = 0
    private var savedRevision = 0
    private var nextRevision = 1
    private(set) var contentVersion = 0
    private var contentChangeObservers: [(id: UUID, callback: (EditorContentChange) -> Void)] = []
    private var queuedContentChanges: [EditorContentChange] = []
    private var isDispatchingContentChanges = false

    init(text: String, lineStarts: [Int]? = nil) {
        let trace = EditorLoadTrace()
        buffer = RopeBuffer(text)
        trace.checkpoint("build-rope")
        starts = lineStarts ?? ([0] + text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset + 1 : nil })
        trace.checkpoint(lineStarts == nil ? "build-line-index" : "reuse-line-index")
    }
    var length: Int { buffer.range.length }
    var lineCount: Int { starts.count }
    var isModified: Bool { revision != savedRevision }
    var canUndo: Bool { !undoStack.isEmpty || pending != nil }
    var canRedo: Bool { !redoStack.isEmpty }

    func addContentChangeObserver(_ observer: @escaping (EditorContentChange) -> Void) -> UUID {
        let id = UUID()
        contentChangeObservers.append((id, observer))
        return id
    }
    func removeContentChangeObserver(_ id: UUID) {
        contentChangeObservers.removeAll { $0.id == id }
    }

    func text(in range: NSRange) -> String {
        precondition(range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= length)
        // Our callers use validated UTF-16 coordinates; buffer failures indicate a bug.
        return try! buffer.content(in: range)
    }
    func lineRange(_ index: Int) -> NSRange {
        let index = min(max(0, index), starts.count - 1)
        let end = index + 1 < starts.count ? starts[index + 1] - 1 : length
        return NSRange(location: starts[index], length: end - starts[index])
    }
    func lineIndex(at offset: Int) -> Int {
        let offset = min(max(0, offset), length)
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }
    func replace(_ range: NSRange, with text: String) {
        let text = EditorDocuments.normalizeNewlines(text)
        let before = self.text(in: range)
        guard before != text else { return }
        let change = Change(offset: range.location, before: before, after: text)
        let oldRevision = revision
        apply(range, text)
        revision = nextRevision
        nextRevision += 1
        redoStack.removeAll()
        if grouping {
            if pending == nil { pending = Edit(changes: [], beforeRevision: oldRevision, afterRevision: revision) }
            pending?.changes.append(change)
            pending?.afterRevision = revision
        } else {
            undoStack.append(Edit(changes: [change], beforeRevision: oldRevision, afterRevision: revision))
        }
        publishChange([EditorContentDelta(range: range, insertedText: text)])
    }
    private func publishChange(_ changes: [EditorContentDelta]) {
        queuedContentChanges.append(EditorContentChange(changes: changes, version: contentVersion))
        guard !isDispatchingContentChanges else { return }
        isDispatchingContentChanges = true
        defer { isDispatchingContentChanges = false }
        while !queuedContentChanges.isEmpty {
            let change = queuedContentChanges.removeFirst()
            let observers = contentChangeObservers
            for observer in observers { observer.callback(change) }
        }
    }
    private func apply(_ range: NSRange, _ text: String) {
        let first = lineIndex(at: range.location) + 1
        let last = lineIndex(at: NSMaxRange(range)) + 1
        let delta = text.utf16.count - range.length
        let inserted = text.utf16.enumerated().compactMap { $0.element == 10 ? range.location + $0.offset + 1 : nil }
        starts.replaceSubrange(first..<last, with: inserted)
        for index in (first + inserted.count)..<starts.count { starts[index] += delta }
        try! buffer.replace(range: range, with: text)
        contentVersion += 1
    }
    func beginUndoGroup() {
        guard !grouping else { return }
        grouping = true
    }
    func endUndoGroup() {
        if let pending { undoStack.append(pending) }
        pending = nil
        grouping = false
    }
    func undo() -> NSRange? {
        endUndoGroup()
        guard let edit = undoStack.popLast() else { return nil }
        var deltas: [EditorContentDelta] = []
        for change in edit.changes.reversed() {
            let range = NSRange(location: change.offset, length: change.after.utf16.count)
            apply(range, change.before)
            deltas.append(EditorContentDelta(range: range, insertedText: change.before))
        }
        revision = edit.beforeRevision
        redoStack.append(edit)
        let first = edit.changes[0]
        let selection = NSRange(location: first.offset + first.before.utf16.count, length: 0)
        publishChange(deltas)
        return selection
    }
    func redo() -> NSRange? {
        endUndoGroup()
        guard let edit = redoStack.popLast() else { return nil }
        var deltas: [EditorContentDelta] = []
        for change in edit.changes {
            let range = NSRange(location: change.offset, length: change.before.utf16.count)
            apply(range, change.after)
            deltas.append(EditorContentDelta(range: range, insertedText: change.after))
        }
        revision = edit.afterRevision
        undoStack.append(edit)
        let last = edit.changes.last!
        let selection = NSRange(location: last.offset + last.after.utf16.count, length: 0)
        publishChange(deltas)
        return selection
    }
    func markSaved() { endUndoGroup(); savedRevision = revision }
}
