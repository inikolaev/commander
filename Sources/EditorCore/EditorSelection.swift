import Foundation

/// Cursor and selection behavior is separate from storage and drawing.
public final class EditorSelection {
    public let document: any EditorDocument
    public private(set) var caret = 0
    public private(set) var anchor = 0
    private var preferredColumn: Int?
    public var range: NSRange { NSRange(location: min(anchor, caret), length: abs(caret - anchor)) }
    public var line: Int { document.lineIndex(at: caret) }
    public var column: Int {
        document.text(in: NSRange(location: document.lineRange(line).location,
            length: caret - document.lineRange(line).location)).count
    }
    public init(document: any EditorDocument) { self.document = document }
    public func set(_ offset: Int, extending: Bool = false) {
        caret = min(max(0, offset), document.length)
        if !extending { anchor = caret }
        preferredColumn = nil
    }
    public func select(_ range: NSRange) {
        anchor = min(max(0, range.location), document.length)
        caret = min(NSMaxRange(range), document.length)
        preferredColumn = nil
    }
    public func replace(with text: String) {
        let normalized = EditorDocuments.normalizeNewlines(text)
        let start = range.location
        document.replace(range, with: normalized)
        set(start + normalized.utf16.count)
    }
    public func moveHorizontal(_ direction: Int, extending: Bool) {
        if !extending && range.length > 0 {
            set(direction < 0 ? range.location : NSMaxRange(range)); return
        }
        let lineRange = document.lineRange(line)
        if direction < 0 {
            guard caret > 0 else { return }
            if caret == lineRange.location { set(caret - 1, extending: extending); return }
            let prefix = document.text(in: NSRange(location: lineRange.location, length: caret - lineRange.location))
            set(caret - String(prefix.last!).utf16.count, extending: extending)
        } else {
            guard caret < document.length else { return }
            if caret == NSMaxRange(lineRange) { set(caret + 1, extending: extending); return }
            let suffix = document.text(in: NSRange(location: caret, length: NSMaxRange(lineRange) - caret))
            set(caret + String(suffix.first!).utf16.count, extending: extending)
        }
    }
    public func moveVertical(_ lines: Int, extending: Bool) {
        let column = preferredColumn ?? self.column
        let target = document.lineRange(min(max(0, line + lines), document.lineCount - 1))
        let text = document.text(in: target)
        let offset = text.prefix(column).utf16.count
        set(target.location + offset, extending: extending)
        preferredColumn = column
    }
    public func delete(backward: Bool) {
        if range.length == 0 { moveHorizontal(backward ? -1 : 1, extending: true) }
        replace(with: "")
    }
    public func deleteLine() {
        let index = line
        let column = self.column
        var removal = document.lineRange(index)
        if NSMaxRange(removal) < document.length {
            removal.length += 1 // Include the following newline.
        } else if removal.location > 0 {
            removal.location -= 1 // The last line owns the preceding newline.
            removal.length += 1
        }
        document.replace(removal, with: "")
        let target = document.lineRange(min(index, document.lineCount - 1))
        set(target.location + document.text(in: target).prefix(column).utf16.count)
    }
    public func undo() { if let range = document.undo() { select(range) } }
    public func redo() { if let range = document.redo() { select(range) } }
}
