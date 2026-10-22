import AppKit
import EditorCore
import SyntaxCore

/// Custom terminal rendering; AppKit is used only for keyboard/IME interpretation.
@MainActor
final class TerminalFileEditor: NSView, @preconcurrency NSTextInputClient {
    let document: any EditorDocument
    let selection: EditorSelection
    let path: String
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var topLine = 0
    private var leftOffset: CGFloat = 0
    private var scrollRemainder: CGFloat = 0
    private var marked = NSRange(location: NSNotFound, length: 0)
    private var dragging = false
    private var hasEditorFocus = false
    private let insertionIndicator = EditorInsertionIndicator()
    private var secondaryIndicators: [EditorInsertionIndicator] = []
    private var syntaxController: EditorSyntaxController?
    private var syntaxProjection = EditorSyntaxProjection.empty
    private var cell: CGFloat { TerminalTheme.cellAdvance }
    var visibleRows: Int { textGeometry.visibleRows }
    private var rows: Int { visibleRows }
    private var textGeometry: TerminalTextGeometry { TerminalTextGeometry(bounds: bounds) }
    private var textWidth: CGFloat { max(cell, bounds.width - 4) }

    init(document: any EditorDocument, path: String) {
        self.document = document
        self.selection = EditorSelection(document: document)
        self.path = path
        super.init(frame: .zero)
        addSubview(insertionIndicator.view)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("File editor: \(path)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func startSyntax(initialText: String) {
        syntaxController?.close()
        syntaxProjection = .empty
        syntaxController = EditorSyntaxController(document: document, url: URL(fileURLWithPath: path),
                                                 initialText: initialText) { [weak self] projection in
            self?.syntaxProjection = projection
            self?.needsDisplay = true
        }
    }
    func stopSyntax() {
        syntaxController?.close()
        syntaxController = nil
        syntaxProjection = .empty
    }
    func foregroundColor(for glyphOffset: Int, selected: Bool) -> NSColor {
        if selected { return TerminalTheme.contrastText }
        return syntaxProjection.kind(at: glyphOffset).map { TerminalTheme.syntaxColor(for: $0) } ?? TerminalTheme.accent
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        hasEditorFocus = true
        updateInsertionIndicator(restart: true)
        return true
    }
    override func resignFirstResponder() -> Bool {
        hasEditorFocus = false
        dragging = false
        updateInsertionIndicator()
        return true
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        insertionIndicator.update(.hidden)
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: name, object: window)
            }
        }
        hasEditorFocus = window?.firstResponder === self
        updateInsertionIndicator(restart: true)
    }
    @objc private func windowFocusChanged(_ notification: Notification) {
        updateInsertionIndicator(restart: true)
    }
    override func viewDidHide() {
        super.viewDidHide()
        insertionIndicator.update(.hidden)
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateInsertionIndicator(restart: true)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateInsertionIndicator()
    }

    private func updateInsertionIndicator(restart: Bool = false) {
        for indicator in secondaryIndicators { indicator.update(.hidden) }
        let secondary = Array(selection.carets.dropFirst()).filter {
            $0.range.length == 0 && $0.line >= topLine && $0.line < topLine + rows
        }
        while secondaryIndicators.count < secondary.count {
            let indicator = EditorInsertionIndicator()
            secondaryIndicators.append(indicator)
            addSubview(indicator.view)
        }
        if hasEditorFocus, window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor {
            for (indicator, caret) in zip(secondaryIndicators, secondary) {
                let rect = NSRect(x: 2 + cursorX(for: caret) - leftOffset,
                    y: CGFloat(caret.line - topLine + 1) * TerminalTheme.lineHeight + 1,
                    width: 2, height: TerminalTheme.lineHeight - 2).intersection(textGeometry.contentRect)
                if !rect.isEmpty {
                    indicator.view.frame = rect
                    indicator.update(dragging ? .visible : .blinking, restart: restart)
                }
            }
        }
        guard hasEditorFocus, window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor,
              selection.range.length == 0, selection.line >= topLine, selection.line < topLine + rows else {
            insertionIndicator.update(.hidden)
            return
        }
        let rect = NSRect(x: 2 + cursorX() - leftOffset,
            y: CGFloat(selection.line - topLine + 1) * TerminalTheme.lineHeight + 1,
            width: 2, height: TerminalTheme.lineHeight - 2).intersection(textGeometry.contentRect)
        guard !rect.isEmpty else { insertionIndicator.update(.hidden); return }
        insertionIndicator.view.frame = rect
        insertionIndicator.update(dragging || hasMarkedText() ? .visible : .blinking, restart: restart)
    }

    private struct Glyph {
        let text: String
        let offset: Int
        let length: Int
        let x: CGFloat
        let width: CGFloat
    }
    private func characterWidth(_ text: String, at x: CGFloat) -> CGFloat {
        if text == "\t" {
            let tabStop = 4 * cell
            return tabStop - x.truncatingRemainder(dividingBy: tabStop)
        }
        return max(cell, (text as NSString).size(withAttributes: [.font: TerminalTheme.font]).width)
    }
    private func glyphs(_ line: Int) -> [Glyph] {
        let range = document.lineRange(line)
        var offset = range.location
        var x: CGFloat = 0
        var result: [Glyph] = []
        for character in document.text(in: range) {
            let string = String(character)
            let width = characterWidth(string, at: x)
            if x + width > leftOffset {
                // Keep a bounded list of visible glyphs, including for a huge single line.
                let display = character == "\t" ? "" :
                    string.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ? "·" : string
                result.append(Glyph(text: display, offset: offset, length: string.utf16.count, x: x, width: width))
            }
            offset += string.utf16.count
            x += width
            if x > leftOffset + textWidth { break }
        }
        return result
    }
    private func cursorX(for selection: EditorSelection) -> CGFloat {
        let start = document.lineRange(selection.line).location
        let prefix = document.text(in: NSRange(location: start, length: selection.caret - start))
        var x: CGFloat = 0
        for character in prefix {
            let width = characterWidth(String(character), at: x)
            x += width
        }
        return x
    }
    private func cursorX() -> CGFloat { cursorX(for: selection) }
    func changed(ensureVisible: Bool = true) {
        selection.coalesceCarets()
        if ensureVisible {
            topLine = min(topLine, selection.line)
            topLine = max(topLine, selection.line - rows + 1)
            let x = cursorX()
            leftOffset = min(leftOffset, x)
            leftOffset = max(leftOffset, x - textWidth + cell)
        }
        topLine = min(max(0, topLine), max(0, document.lineCount - 1))
        updateInsertionIndicator(restart: true)
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
        let status = "\(document.isModified ? "*" : "") UTF-8  Ln \(selection.line + 1)/\(document.lineCount) Col \(selection.column + 1)\(selection.caretCount > 1 ? "  Carets \(selection.caretCount)" : "")"
        let statusWidth = min(bounds.width * 0.7, CGFloat(status.count + 2) * cell)
        TerminalTheme.text(path, in: NSRect(x: 2, y: 0, width: bounds.width - statusWidth - 6, height: height), color: TerminalTheme.contrastText)
        TerminalTheme.text(status, in: NSRect(x: bounds.width - statusWidth, y: 0, width: statusWidth - 2, height: height),
            color: TerminalTheme.contrastText, alignment: .right)
        NSGraphicsContext.saveGraphicsState()
        textGeometry.contentRect.clip()
        for row in 0..<rows {
            let line = topLine + row
            guard line < document.lineCount else { break }
            let y = CGFloat(row + 1) * height
            let range = document.lineRange(line)
            for glyph in glyphs(line) {
                guard glyph.x + glyph.width > leftOffset else { continue }
                if glyph.x >= leftOffset + textWidth { break }
                let rect = NSRect(x: 2 + glyph.x - leftOffset, y: y,
                    width: glyph.width, height: height)
                let selected = selection.ranges.contains { NSIntersectionRange($0, NSRange(location: glyph.offset, length: glyph.length)).length > 0 }
                if selected { TerminalTheme.selection.setFill(); rect.fill() }
                // Draw composed graphemes intact (including emoji ZWJ sequences).
                NSGraphicsContext.saveGraphicsState()
                rect.clip()
                (glyph.text as NSString).draw(in: rect, withAttributes: [
                    .font: TerminalTheme.font,
                    .foregroundColor: foregroundColor(for: glyph.offset, selected: selected),
                ])
                NSGraphicsContext.restoreGraphicsState()
                if marked.location != NSNotFound && NSIntersectionRange(marked, NSRange(location: glyph.offset, length: glyph.length)).length > 0 {
                    TerminalTheme.heading.setFill()
                    NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1).fill()
                }
            }
            // Make a selected newline visible even on an otherwise empty line.
            if selection.ranges.contains(where: { $0.location <= NSMaxRange(range) && NSMaxRange($0) > NSMaxRange(range) }) {
                let visible = glyphs(line)
                let end = visible.last.map { $0.x + $0.width } ?? 0
                let x = 2 + end - leftOffset
                if (visible.last.map { $0.offset + $0.length } ?? range.location) == NSMaxRange(range), x >= 2 && x < bounds.width {
                    TerminalTheme.selection.setFill()
                    NSRect(x: x, y: y, width: cell, height: height).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        TerminalFunctionKeys.draw(in: footerRect, labels: [2: "Save", 10: "Close"])
    }
    private var footerRect: NSRect {
        NSRect(x: 0, y: bounds.height - TerminalTheme.lineHeight, width: bounds.width, height: TerminalTheme.lineHeight)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains([.command, .option]),
           !event.modifierFlags.contains(.shift), [125, 126].contains(event.keyCode) {
            unmarkText()
            selection.addCaretVertically(event.keyCode == 126 ? -1 : 1)
            changed()
            return
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": unmarkText(); onSave?()
            case "z": unmarkText(); event.modifierFlags.contains(.shift) ? selection.redo() : selection.undo(); changed()
            case "y": unmarkText(); selection.deleteLine(); changed()
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
            case 53:
                if selection.caretCount > 1 { selection.clearAdditionalCarets(); changed() }
                else { onClose?() }
                return
            case 109: onClose?(); return
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
        case "moveLeft:", "moveBackward:": selection.forEachCaret { $0.moveHorizontal(-1, extending: extending) }
        case "moveRight:", "moveForward:": selection.forEachCaret { $0.moveHorizontal(1, extending: extending) }
        case "moveWordLeft:", "moveWordBackward:": selection.forEachCaret { moveWord(-1, caret: $0, extending: extending) }
        case "moveWordRight:", "moveWordForward:": selection.forEachCaret { moveWord(1, caret: $0, extending: extending) }
        case "moveUp:": selection.moveCaretsVertically(-1, extending: extending)
        case "moveDown:": selection.moveCaretsVertically(1, extending: extending)
        case "pageUp:", "scrollPageUp:": movePage(-1, extending: extending)
        case "pageDown:", "scrollPageDown:": movePage(1, extending: extending)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:": selection.forEachCaret { $0.set(document.lineRange($0.line).location, extending: extending) }
        case "moveToEndOfLine:", "moveToRightEndOfLine:": selection.forEachCaret { $0.set(NSMaxRange(document.lineRange($0.line)), extending: extending) }
        case "moveToBeginningOfDocument:", "scrollToBeginningOfDocument:": selection.forEachCaret { $0.set(0, extending: extending) }
        case "moveToEndOfDocument:", "scrollToEndOfDocument:": selection.forEachCaret { $0.set(document.length, extending: extending) }
        case "deleteBackward:": selection.delete(backward: true)
        case "deleteForward:": selection.delete(backward: false)
        case "insertNewline:": selection.replace(with: "\n")
        case "insertTab:": selection.replace(with: "\t")
        case "cancelOperation:":
            if selection.caretCount > 1 { selection.clearAdditionalCarets() }
            else { onClose?() }
        default: super.doCommand(by: selector)
        }
        changed()
    }
    private func moveWord(_ direction: Int, caret selection: EditorSelection, extending: Bool) {
        let forward = direction > 0
        var line = selection.line
        let current = document.lineRange(line)
        if forward && selection.caret == NSMaxRange(current) && line + 1 < document.lineCount {
            line += 1
        } else if !forward && selection.caret == current.location && line > 0 {
            line -= 1
        }
        // Use AppKit's Unicode word boundaries without copying the entire document.
        let range = document.lineRange(line)
        let text = NSAttributedString(string: document.text(in: range))
        let start = min(max(0, selection.caret - range.location), text.length)
        selection.set(range.location + text.nextWord(from: start, forward: forward), extending: extending)
    }
    private func movePage(_ direction: Int, extending: Bool) {
        let distance = selection.moveCaretsVertically(direction * rows, extending: extending)
        topLine = min(max(0, topLine + distance), max(0, document.lineCount - rows))
    }
    private func wordRange(at offset: Int) -> NSRange? {
        let lineRange = document.lineRange(document.lineIndex(at: offset))
        let line = document.text(in: lineRange)
        let local = offset - lineRange.location
        let characters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        var parts: [(start: Int, end: Int, word: Bool)] = []
        var position = 0
        for character in line {
            let end = position + String(character).utf16.count
            parts.append((position, end, character.unicodeScalars.contains { characters.contains($0) }))
            position = end
        }
        guard let index = parts.firstIndex(where: { $0.word && $0.start <= local && local <= $0.end }) else { return nil }
        var first = index
        var last = index
        while first > 0 && parts[first - 1].word { first -= 1 }
        while last + 1 < parts.count && parts[last + 1].word { last += 1 }
        return NSRange(location: lineRange.location + parts[first].start,
            length: parts[last].end - parts[first].start)
    }

    @objc func copy(_ sender: Any?) {
        let ranges = selection.ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard !ranges.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ranges.map { document.text(in: $0) }.joined(separator: "\n"), forType: .string)
    }
    @objc func cut(_ sender: Any?) { unmarkText(); copy(sender); selection.replace(with: ""); changed() }
    @objc func paste(_ sender: Any?) {
        unmarkText()
        if let text = NSPasteboard.general.string(forType: .string) {
            let normalized = EditorDocuments.normalizeNewlines(text)
            let lines = normalized.components(separatedBy: "\n")
            if selection.caretCount > 1 && lines.count == selection.caretCount {
                selection.replace(with: lines)
            } else {
                selection.replace(with: normalized)
            }
            changed()
        }
    }
    override func selectAll(_ sender: Any?) {
        unmarkText()
        selection.clearAdditionalCarets()
        selection.select(NSRange(location: 0, length: document.length))
        changed()
    }

    // Native text input handles dead keys, keyboard layouts and IME composition.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let replacement = replacementRange.location != NSNotFound ? replacementRange : hasMarkedText() ? marked : selection.range
        if replacementRange.location != NSNotFound || hasMarkedText() { selection.clearAdditionalCarets() }
        if selection.caretCount == 1 || replacementRange.location != NSNotFound || hasMarkedText() {
            selection.select(safeRange(replacement))
        }
        selection.replace(with: text)
        unmarkText()
        changed()
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let replacement = safeRange(replacementRange.location != NSNotFound ? replacementRange : hasMarkedText() ? marked : selection.range)
        selection.clearAdditionalCarets()
        if !hasMarkedText() { document.beginUndoGroup() }
        document.replace(replacement, with: text)
        marked = NSRange(location: replacement.location, length: EditorDocuments.normalizeNewlines(text).utf16.count)
        selection.select(safeRange(NSRange(location: marked.location + selectedRange.location, length: selectedRange.length)))
        changed()
    }
    func unmarkText() {
        marked = NSRange(location: NSNotFound, length: 0)
        document.endUndoGroup()
        updateInsertionIndicator(restart: true)
        needsDisplay = true
    }
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
        let rect = NSRect(x: 2 + cursorX() - leftOffset,
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
        let x = max(0, leftOffset + point.x - 2)
        let visible = glyphs(line)
        return visible.first(where: { x < $0.x + $0.width / 2 })?.offset ??
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
        let offset = offset(at: point)
        if event.modifierFlags.contains([.option, .shift]) {
            if event.clickCount >= 2, let word = wordRange(at: offset) {
                _ = selection.addSelection(word)
            } else {
                _ = selection.toggleCaret(at: offset)
            }
        } else {
            selection.clearAdditionalCarets()
            if event.clickCount >= 2, let word = wordRange(at: offset) {
                selection.select(word)
            } else {
                selection.set(offset, extending: event.modifierFlags.contains(.shift))
            }
        }
        dragging = true
        changed()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        selection.set(offset(at: convert(event.locationInWindow, from: nil)), extending: true)
        changed()
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        updateInsertionIndicator(restart: true)
    }
    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? TerminalTheme.lineHeight : 1)
        let steps = Int(scrollRemainder)
        topLine -= steps
        scrollRemainder -= CGFloat(steps)
        changed(ensureVisible: false)
    }
}
