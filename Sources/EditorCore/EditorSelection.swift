import Foundation

/// Cursor and selection behavior is separate from storage and drawing.
public final class EditorSelection {
    public static let maximumCaretCount = 1000
    public let document: any EditorDocument
    private var additionalCarets: [EditorSelection] = []
    public var carets: [EditorSelection] { [self] + additionalCarets }
    public var ranges: [NSRange] { carets.map(\.range) }
    public var caretCount: Int { 1 + additionalCarets.count }
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
    public func clearAdditionalCarets() { additionalCarets.removeAll() }
    @discardableResult public func toggleCaret(at offset: Int) -> Bool {
        let position = min(max(0, offset), document.length)
        if let index = additionalCarets.firstIndex(where: { $0.range.length == 0 && $0.caret == position }) {
            additionalCarets.remove(at: index)
            return false
        }
        if caret == position && range.length == 0 {
            if !additionalCarets.isEmpty {
                let next = additionalCarets.removeLast()
                anchor = next.anchor
                caret = next.caret
            }
            return false
        }
        guard caretCount < Self.maximumCaretCount else { return false }
        let previous = EditorSelection(document: document)
        previous.anchor = anchor
        previous.caret = caret
        previous.preferredColumn = preferredColumn
        additionalCarets.append(previous)
        set(position)
        return true
    }
    @discardableResult public func addSelection(_ selectedRange: NSRange) -> Bool {
        guard caretCount < Self.maximumCaretCount else { return false }
        let start = min(max(0, selectedRange.location), document.length)
        let end = min(max(start, NSMaxRange(selectedRange)), document.length)
        let candidate = NSRange(location: start, length: end - start)
        guard !ranges.contains(where: { overlaps($0, candidate) }) else { return false }
        let previous = EditorSelection(document: document)
        previous.anchor = anchor
        previous.caret = caret
        previous.preferredColumn = preferredColumn
        additionalCarets.append(previous)
        select(candidate)
        return true
    }
    public func addCaretVertically(_ direction: Int) {
        let sourceCaret = caret
        let sourceAnchor = anchor
        let sourceColumn = preferredColumn
        let currentLine = line
        guard (0..<document.lineCount).contains(currentLine + direction) else { return }
        moveVertical(direction, extending: false)
        let destination = caret
        caret = sourceCaret
        anchor = sourceAnchor
        preferredColumn = sourceColumn
        guard !carets.contains(where: { $0.caret == destination && $0.range.length == 0 }) else { return }
        _ = toggleCaret(at: destination)
    }
    public func forEachCaret(_ action: (EditorSelection) -> Void) {
        for selection in carets { action(selection) }
        coalesceCarets()
    }
    /// Moves the group together, preserving its spacing at document boundaries.
    @discardableResult public func moveCaretsVertically(_ lines: Int, extending: Bool) -> Int {
        guard lines != 0 else { return 0 }
        let currentLines = carets.map(\.line)
        let available = lines < 0 ? -(currentLines.min() ?? 0) :
            document.lineCount - 1 - (currentLines.max() ?? 0)
        let distance = lines < 0 ? max(lines, available) : min(lines, available)
        guard distance != 0 else { return 0 }
        forEachCaret { $0.moveVertical(distance, extending: extending) }
        return distance
    }
    /// Keep the primary caret when positions or selections converge.
    public func coalesceCarets() {
        var occupied = [range]
        additionalCarets.removeAll { candidate in
            let duplicate = occupied.contains { overlaps(candidate.range, $0) }
            if !duplicate { occupied.append(candidate.range) }
            return duplicate
        }
    }
    private func overlaps(_ first: NSRange, _ second: NSRange) -> Bool {
        if first.length == 0 { return first.location >= second.location && first.location <= NSMaxRange(second) }
        if second.length == 0 { return second.location >= first.location && second.location <= NSMaxRange(first) }
        return NSIntersectionRange(first, second).length > 0
    }
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
        coalesceCarets()
        replace(with: Array(repeating: text, count: caretCount))
    }
    /// Texts are assigned in document order, regardless of which caret is primary.
    public func replace(with texts: [String]) {
        coalesceCarets()
        guard texts.count == caretCount else { return }
        let selections = carets.sorted { $0.range.location < $1.range.location }
        let edits = zip(selections, texts.map(EditorDocuments.normalizeNewlines))
            .map { ($0.0, $0.0.range, $0.1) }
        document.beginUndoGroup()
        for (_, range, text) in edits.reversed() { document.replace(range, with: text) }
        document.endUndoGroup()
        var shift = 0
        for (selection, range, text) in edits {
            selection.set(range.location + shift + text.utf16.count)
            shift += text.utf16.count - range.length
        }
        coalesceCarets()
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
        for selection in carets where selection.range.length == 0 {
            selection.moveHorizontal(backward ? -1 : 1, extending: true)
        }
        replace(with: "")
    }
    public func deleteLine() {
        clearAdditionalCarets()
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
    public func undo() { clearAdditionalCarets(); if let range = document.undo() { select(range) } }
    public func redo() { clearAdditionalCarets(); if let range = document.redo() { select(range) } }
}
