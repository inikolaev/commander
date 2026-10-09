import AppKit
import EditorCore

/// Custom terminal rendering; AppKit is used only for keyboard/IME interpretation.
@MainActor
final class TerminalFileEditor: NSView, @preconcurrency NSTextInputClient {
    let document: any EditorDocument
    let selection: EditorSelection
    let path: String
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var topLine = 0
    private var leftColumn = 0
    private var scrollRemainder: CGFloat = 0
    private var marked = NSRange(location: NSNotFound, length: 0)
    private var dragging = false
    private var cell: CGFloat { ceil(("M" as NSString).size(withAttributes: [.font: TerminalTheme.font]).width) }
    var visibleRows: Int { textGeometry.visibleRows }
    private var rows: Int { visibleRows }
    private var textGeometry: TerminalTextGeometry { TerminalTextGeometry(bounds: bounds) }
    private var columns: Int { max(1, Int((bounds.width - 4) / cell)) }

    init(document: any EditorDocument, path: String) {
        self.document = document
        self.selection = EditorSelection(document: document)
        self.path = path
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("File editor: \(path)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private struct Glyph {
        let text: String
        let offset: Int
        let length: Int
        let column: Int
        let width: Int
    }
    private func characterWidth(_ text: String, at column: Int) -> Int {
        if text == "\t" { return 4 - column % 4 }
        return max(1, Int(((text as NSString).size(withAttributes: [.font: TerminalTheme.font]).width / cell).rounded()))
    }
    private func glyphs(_ line: Int) -> [Glyph] {
        let range = document.lineRange(line)
        var offset = range.location
        var column = 0
        var result: [Glyph] = []
        for character in document.text(in: range) {
            let string = String(character)
            let width = characterWidth(string, at: column)
            if column + width > leftColumn {
                // Keep a bounded list of visible cells, including for a huge single line.
                let display = character == "\t" ? "" :
                    string.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ? "·" : string
                result.append(Glyph(text: display, offset: offset, length: string.utf16.count, column: column, width: width))
            }
            offset += string.utf16.count
            column += width
            if column > leftColumn + columns { break }
        }
        return result
    }
    private func cursorColumn() -> Int {
        let start = document.lineRange(selection.line).location
        let prefix = document.text(in: NSRange(location: start, length: selection.caret - start))
        var column = 0
        for character in prefix { column += characterWidth(String(character), at: column) }
        return column
    }
    func changed(ensureVisible: Bool = true) {
        if ensureVisible {
            topLine = min(topLine, selection.line)
            topLine = max(topLine, selection.line - rows + 1)
            let column = cursorColumn()
            leftColumn = min(leftColumn, column)
            leftColumn = max(leftColumn, column - columns + 1)
        }
        topLine = min(max(0, topLine), max(0, document.lineCount - 1))
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        changed()
    }
    override func draw(_ dirtyRect: NSRect) {
        TerminalTheme.background.setFill()
        bounds.fill()
        let height = TerminalTheme.lineHeight
        TerminalTheme.selection.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: height).fill()
        let status = "\(document.isModified ? "*" : "") UTF-8  Ln \(selection.line + 1)/\(document.lineCount) Col \(selection.column + 1)"
        let statusWidth = min(bounds.width * 0.7, CGFloat(status.count + 2) * cell)
        TerminalTheme.text(path, in: NSRect(x: 2, y: 0, width: bounds.width - statusWidth - 6, height: height), color: .black)
        TerminalTheme.text(status, in: NSRect(x: bounds.width - statusWidth, y: 0, width: statusWidth - 2, height: height),
            color: .black, alignment: .right)
        NSGraphicsContext.saveGraphicsState()
        textGeometry.contentRect.clip()
        for row in 0..<rows {
            let line = topLine + row
            guard line < document.lineCount else { break }
            let y = CGFloat(row + 1) * height
            let range = document.lineRange(line)
            for glyph in glyphs(line) {
                guard glyph.column + glyph.width > leftColumn else { continue }
                if glyph.column >= leftColumn + columns { break }
                let rect = NSRect(x: 2 + CGFloat(glyph.column - leftColumn) * cell, y: y,
                    width: CGFloat(glyph.width) * cell, height: height)
                let selected = NSIntersectionRange(selection.range, NSRange(location: glyph.offset, length: glyph.length)).length > 0
                if selected { TerminalTheme.selection.setFill(); rect.fill() }
                // Draw composed graphemes intact (including emoji ZWJ sequences).
                NSGraphicsContext.saveGraphicsState()
                rect.clip()
                (glyph.text as NSString).draw(in: rect, withAttributes: [
                    .font: TerminalTheme.font, .foregroundColor: selected ? TerminalTheme.contrastText : TerminalTheme.accent,
                ])
                NSGraphicsContext.restoreGraphicsState()
                if marked.location != NSNotFound && NSIntersectionRange(marked, NSRange(location: glyph.offset, length: glyph.length)).length > 0 {
                    TerminalTheme.heading.setFill()
                    NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1).fill()
                }
            }
            // Make a selected newline visible even on an otherwise empty line.
            if selection.range.location <= NSMaxRange(range) && NSMaxRange(selection.range) > NSMaxRange(range) {
                let visible = glyphs(line)
                let end = visible.last.map { $0.column + $0.width } ?? 0
                let x = 2 + CGFloat(end - leftColumn) * cell
                if (visible.last.map { $0.offset + $0.length } ?? range.location) == NSMaxRange(range), x >= 2 && x < bounds.width {
                    TerminalTheme.selection.setFill()
                    NSRect(x: x, y: y, width: cell, height: height).fill()
                }
            }
        }
        if window?.firstResponder === self && selection.line >= topLine && selection.line < topLine + rows {
            TerminalTheme.primaryText.setFill()
            NSRect(x: 2 + CGFloat(cursorColumn() - leftColumn) * cell,
                y: CGFloat(selection.line - topLine + 1) * height + 1, width: 2, height: height - 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        TerminalFunctionKeys.draw(in: footerRect, labels: [2: "Save", 10: "Close"])
    }
    private var footerRect: NSRect {
        NSRect(x: 0, y: bounds.height - TerminalTheme.lineHeight, width: bounds.width, height: TerminalTheme.lineHeight)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": unmarkText(); onSave?()
            case "z": unmarkText(); event.modifierFlags.contains(.shift) ? selection.redo() : selection.undo(); changed()
            case "a": selectAll(nil)
            case "c": copy(nil)
            case "x": cut(nil)
            case "v": paste(nil)
            default: interpretKeyEvents([event])
            }
            return
        }
        if !hasMarkedText() {
            switch event.keyCode {
            case 120: onSave?(); return // F2
            case 53, 109: onClose?(); return
            default: break
            }
        }
        interpretKeyEvents([event])
    }
    override func doCommand(by selector: Selector) {
        let extending = selector.description.contains("AndModifySelection")
        let command = selector.description.replacingOccurrences(of: "AndModifySelection", with: "")
        unmarkText()
        switch command {
        case "moveLeft:", "moveBackward:": selection.moveHorizontal(-1, extending: extending)
        case "moveRight:", "moveForward:": selection.moveHorizontal(1, extending: extending)
        case "moveUp:": selection.moveVertical(-1, extending: extending)
        case "moveDown:": selection.moveVertical(1, extending: extending)
        case "pageUp:", "scrollPageUp:": movePage(-1, extending: extending)
        case "pageDown:", "scrollPageDown:": movePage(1, extending: extending)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:": selection.set(document.lineRange(selection.line).location, extending: extending)
        case "moveToEndOfLine:", "moveToRightEndOfLine:": selection.set(NSMaxRange(document.lineRange(selection.line)), extending: extending)
        case "moveToBeginningOfDocument:", "scrollToBeginningOfDocument:": selection.set(0, extending: extending)
        case "moveToEndOfDocument:", "scrollToEndOfDocument:": selection.set(document.length, extending: extending)
        case "deleteBackward:": selection.delete(backward: true)
        case "deleteForward:": selection.delete(backward: false)
        case "insertNewline:": selection.replace(with: "\n")
        case "insertTab:": selection.replace(with: "\t")
        case "cancelOperation:": onClose?()
        default: super.doCommand(by: selector)
        }
        changed()
    }
    private func movePage(_ direction: Int, extending: Bool) {
        let distance = direction * rows
        selection.moveVertical(distance, extending: extending)
        topLine = min(max(0, topLine + distance), max(0, document.lineCount - rows))
    }

    @objc func copy(_ sender: Any?) {
        guard selection.range.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.text(in: selection.range), forType: .string)
    }
    @objc func cut(_ sender: Any?) { unmarkText(); copy(sender); selection.replace(with: ""); changed() }
    @objc func paste(_ sender: Any?) {
        unmarkText()
        if let text = NSPasteboard.general.string(forType: .string) { selection.replace(with: text); changed() }
    }
    override func selectAll(_ sender: Any?) {
        unmarkText()
        selection.select(NSRange(location: 0, length: document.length))
        changed()
    }

    // Native text input handles dead keys, keyboard layouts and IME composition.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let replacement = replacementRange.location != NSNotFound ? replacementRange : hasMarkedText() ? marked : selection.range
        selection.select(safeRange(replacement))
        selection.replace(with: text)
        unmarkText()
        changed()
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let replacement = safeRange(replacementRange.location != NSNotFound ? replacementRange : hasMarkedText() ? marked : selection.range)
        if !hasMarkedText() { document.beginUndoGroup() }
        document.replace(replacement, with: text)
        marked = NSRange(location: replacement.location, length: EditorDocuments.normalizeNewlines(text).utf16.count)
        selection.select(safeRange(NSRange(location: marked.location + selectedRange.location, length: selectedRange.length)))
        changed()
    }
    func unmarkText() { marked = NSRange(location: NSNotFound, length: 0); document.endUndoGroup(); needsDisplay = true }
    func hasMarkedText() -> Bool { marked.location != NSNotFound }
    func markedRange() -> NSRange { marked }
    func selectedRange() -> NSRange { selection.range }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= document.length else { return nil }
        let range = safeRange(range)
        actualRange?.pointee = range
        return NSAttributedString(string: document.text(in: range))
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = selection.range
        let rect = NSRect(x: 2 + CGFloat(cursorColumn() - leftColumn) * cell,
            y: CGFloat(selection.line - topLine + 1) * TerminalTheme.lineHeight, width: cell, height: TerminalTheme.lineHeight)
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        return offset(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }
    private func safeRange(_ range: NSRange) -> NSRange {
        let start = min(max(0, range.location), document.length)
        return NSRange(location: start, length: min(max(0, range.length), document.length - start))
    }
    private func offset(at point: NSPoint) -> Int {
        let line = min(max(0, topLine + Int(point.y / TerminalTheme.lineHeight) - 1), document.lineCount - 1)
        let column = max(0, CGFloat(leftColumn) + (point.x - 2) / cell)
        let visible = glyphs(line)
        return visible.first(where: { column < CGFloat($0.column) + CGFloat($0.width) / 2 })?.offset ??
            visible.last.map { $0.offset + $0.length } ?? NSMaxRange(document.lineRange(line))
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let number = TerminalFunctionKeys.number(at: point, in: footerRect) {
            unmarkText()
            if number == 2 { onSave?() } else if number == 10 { onClose?() }
            return
        }
        window?.makeFirstResponder(self)
        unmarkText()
        selection.set(offset(at: point), extending: event.modifierFlags.contains(.shift))
        dragging = true
        changed()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        selection.set(offset(at: convert(event.locationInWindow, from: nil)), extending: true)
        changed()
    }
    override func mouseUp(with event: NSEvent) { dragging = false }
    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? TerminalTheme.lineHeight : 1)
        let steps = Int(scrollRemainder)
        topLine -= steps
        scrollRemainder -= CGFloat(steps)
        changed(ensureVisible: false)
    }
}
