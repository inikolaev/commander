import AppKit
import FileManagerCore
import SyntaxCore

@MainActor
final class TerminalFileViewer: NSView {
    enum Input { case navigate(ViewerCommand), close, toggleMode, toggleWrap, toggleWrapType,
        search(DocumentSearchKeyAction) }
    var onInput: ((Input) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onWordContinuationNeeded: ((ViewerWordContinuationRequest) -> Void)?
    let path: String
    private let syntaxHighlighter: any SyntaxHighlighter
    var syntaxHighlightingEnabled: Bool { syntaxHighlighter.isActive }
    private var syntaxProjection = ViewerSyntaxProjection.empty
    private(set) var page: ViewerPage?
    private struct Position: Comparable {
        let row: Int
        let column: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
        }
    }
    private var anchor: Position?
    private var endpoint: Position?
    private var isSelecting = false
    private var wordSelectedOnMouseDown = false
    private var isWordSelection = false
    private var wordSelectionToken: UInt64 = 0
    private var wordPrefix = ""
    private var wordSuffix = ""
    private var wordClickPosition: Position?
    private var isResolvingWord = false
    private var pendingCopyChangeCount: Int?
    private var selection: (start: Position, end: Position)? {
        guard let anchor, let endpoint, anchor != endpoint else { return nil }
        return (min(anchor, endpoint), max(anchor, endpoint))
    }
    var selectedText: String {
        guard let page, let selection else { return "" }
        let visible = (selection.start.row...selection.end.row).map { row in
            let text = page.lines[row].text
            let start = row == selection.start.row ? selection.start.column : 0
            let end = row == selection.end.row ? selection.end.column : text.count
            return String(text.dropFirst(start).prefix(end - start))
        }.joined(separator: isWordSelection ? "" : "\n")
        return wordPrefix + visible + wordSuffix
    }
    private(set) var horizontalOffset = 0
    var activeSearchRange: Range<Int64>? { didSet { needsDisplay = true } }
    var searchActive = false {
        didSet {
            guard oldValue != searchActive else { return }
            needsDisplay = true
            onResize?()
        }
    }
    var wrapsText = true {
        didSet {
            if wrapsText { horizontalOffset = 0 }
            needsDisplay = true
        }
    }
    var wrapStyle: ViewerWrapStyle = .character { didSet { needsDisplay = true } }
    private var scrollRemainder: CGFloat = 0
    var onResize: (() -> Void)?
    private var contentBounds: NSRect {
        var result = bounds
        if searchActive { result.size.height = max(0, result.height - DocumentSearchSurface.height) }
        return result
    }
    var visibleRows: Int { min(200, TerminalTextGeometry(bounds: contentBounds).visibleRows) }
    var visibleColumns: Int { max(1, Int(floor((bounds.width - 2) / TerminalTheme.cellAdvance))) }

    init(
        path: String,
        syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter.shared
    ) {
        self.path = path
        self.syntaxHighlighter = syntaxHighlighter
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Read-only file viewer: \(path)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(_ page: ViewerPage, syntaxProjection: ViewerSyntaxProjection = .empty) {
        if self.page?.mode != page.mode || wrapsText { horizontalOffset = 0 }
        if self.page?.mode != page.mode || self.page?.offset != page.offset
            || self.page?.revision != page.revision
            || (self.page?.fileSize != nil && page.fileSize != nil && self.page?.fileSize != page.fileSize)
            || self.page?.lines.map(\.text) != page.lines.map(\.text)
            || self.page?.lines.map(\.offset) != page.lines.map(\.offset)
            || self.page?.lines.map(\.endOffset) != page.lines.map(\.endOffset) {
            onSelectionChanged?()
            anchor = nil
            endpoint = nil
            isSelecting = false
            wordSelectedOnMouseDown = false
            isWordSelection = false
            invalidateWordContinuation()
        }
        self.page = page
        self.syntaxProjection = syntaxProjection
        setAccessibilityValue(page.lines.map(\.text).joined(separator: "\n"))
        needsDisplay = true
    }

    func revealSearchColumn() {
        guard let page, let activeSearchRange, !wrapsText,
              let row = page.lines.first(where: { $0.offset <= activeSearchRange.lowerBound &&
                  activeSearchRange.lowerBound < $0.endOffset }),
              let first = row.searchColumns.map(\.lowerBound).min() else { return }
        if first < horizontalOffset { horizontalOffset = first }
        else if first >= horizontalOffset + visibleColumns {
            horizontalOffset = max(0, first - visibleColumns + 1)
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldRows = visibleRows
        let oldColumns = visibleColumns
        super.setFrameSize(newSize)
        needsDisplay = true
        if oldRows != visibleRows || oldColumns != visibleColumns { onResize?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        TerminalTheme.background.setFill()
        bounds.fill()
        let line = TerminalTheme.lineHeight
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: line)
        let footer = NSRect(x: 0, y: bounds.height - line, width: bounds.width, height: line)
        TerminalTheme.selection.setFill()
        header.fill()
        let percent = page.flatMap { page in page.fileSize.map { $0 == 0 ? 100 : Int(Double(page.endOffset) / Double($0) * 100) } }
        let position = page.map { "Byte \($0.offset.formatted())/\($0.fileSize?.formatted() ?? "?")" } ?? "Opening…"
        let encoding = page?.mode == .hex ? "HEX / ASCII" : "UTF-8"
        let wrapping = page?.mode == .text && wrapsText
            ? (wrapStyle == .word ? "Wrap: Words" : "Wrap: Characters") : "No wrap"
        let status = "\(encoding)   \(wrapping)   \(position)   Col \(horizontalOffset + 1)   \(percent.map { "\($0)%" } ?? "")"
        let statusWidth = min(bounds.width * 0.76, ceil((status as NSString).size(withAttributes: [.font: TerminalTheme.font]).width))
        TerminalTheme.text(path, in: NSRect(x: 1, y: 0, width: max(0, bounds.width - statusWidth - 16), height: line), color: TerminalTheme.contrastText)
        TerminalTheme.text(status, in: NSRect(x: bounds.width - statusWidth - 2, y: 0,
            width: statusWidth, height: line), color: TerminalTheme.contrastText, alignment: .right)
        drawFunctionKeys(in: footer)
        NSGraphicsContext.saveGraphicsState()
        TerminalTextGeometry(bounds: contentBounds).contentRect.clip()
        if let page {
            for (index, row) in page.lines.prefix(visibleRows).enumerated() {
                let rect = NSRect(x: 1, y: CGFloat(index + 1) * line, width: bounds.width - 2, height: line)
                if rect.intersects(dirtyRect) {
                    let displayed = String(row.text.dropFirst(horizontalOffset).prefix(visibleColumns))
                    TerminalTheme.text(displayed, in: rect, color: TerminalTheme.accent, truncate: .byClipping)
                    if page.mode == .text {
                        drawSyntaxHighlights(forRow: index, displayed: displayed, in: rect)
                    }
                    if selection == nil {
                        for range in visibleSearchColumns(forRow: index) {
                            let start = max(range.lowerBound, horizontalOffset)
                            let end = min(range.upperBound, horizontalOffset + visibleColumns)
                            guard end > start else { continue }
                            let left = rect.minX + textWidth(String(displayed.prefix(start - horizontalOffset)))
                            let right = rect.minX + textWidth(String(displayed.prefix(end - horizontalOffset)))
                            NSGraphicsContext.saveGraphicsState()
                            NSRect(x: left, y: rect.minY, width: max(1, right - left), height: rect.height).clip()
                            TerminalTheme.selection.setFill()
                            rect.fill()
                            TerminalTheme.text(displayed, in: rect, color: TerminalTheme.contrastText, truncate: .byClipping)
                            NSGraphicsContext.restoreGraphicsState()
                        }
                    }
                    if let selection, index >= selection.start.row, index <= selection.end.row {
                        let start = index == selection.start.row ? selection.start.column : 0
                        let end = index == selection.end.row ? selection.end.column : row.text.count
                        let left = rect.minX + textWidth(String(displayed.prefix(max(0, start - horizontalOffset))))
                        var right = rect.minX + textWidth(String(displayed.prefix(max(0, end - horizontalOffset))))
                        // Give selected line breaks a visible cell, including on empty lines.
                        if index < selection.end.row && !isWordSelection { right += textWidth(" ") }
                        if right > left {
                            NSGraphicsContext.saveGraphicsState()
                            NSRect(x: left, y: rect.minY, width: right - left, height: rect.height).clip()
                            TerminalTheme.selection.setFill()
                            rect.fill()
                            TerminalTheme.text(displayed, in: rect, color: TerminalTheme.contrastText, truncate: .byClipping)
                            NSGraphicsContext.restoreGraphicsState()
                        }
                    }
                }
            }
            if page.fileSize == 0 {
                TerminalTheme.text("Empty file", in: NSRect(x: 8, y: line, width: bounds.width - 16, height: line))
            }
        } else {
            TerminalTheme.text("Opening file…", in: NSRect(x: 8, y: line, width: bounds.width - 16, height: line))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    func visibleSearchColumns(forRow index: Int) -> [Range<Int>] {
        guard activeSearchRange != nil, let page, page.lines.indices.contains(index) else { return [] }
        return page.lines[index].searchColumns
    }

    private func drawSyntaxHighlights(forRow row: Int, displayed: String, in rect: NSRect) {
        guard syntaxProjection.lines.indices.contains(row) else { return }
        let visibleEnd = horizontalOffset + visibleColumns
        for highlight in syntaxProjection.lines[row] {
            if highlight.range.upperBound <= horizontalOffset { continue }
            if highlight.range.lowerBound >= visibleEnd { break }

            let start = max(highlight.range.lowerBound, horizontalOffset)
            let end = min(highlight.range.upperBound, visibleEnd)
            guard start < end else { continue }

            let relativeStart = start - horizontalOffset
            let prefix = String(displayed.prefix(relativeStart))
            let token = String(displayed.dropFirst(relativeStart).prefix(end - start))
            guard !token.isEmpty else { continue }

            let x = rect.minX + textWidth(prefix)
            guard x < rect.maxX else { continue }
            TerminalTheme.text(
                token,
                in: NSRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height),
                color: TerminalTheme.syntaxColor(for: highlight.kind),
                truncate: .byClipping
            )
        }
    }

    private func drawFunctionKeys(in footer: NSRect) {
        TerminalFunctionKeys.draw(in: footer, labels: [
            2: wrapsText ? "Unwrap" : "Wrap",
            3: "Close",
            4: page?.mode == .hex ? "Text" : "Hex",
            7: "Search",
            10: "Quit",
        ])
    }

    override func keyDown(with event: NSEvent) {
        let searchAction = DocumentSearchKeyAction.action(for: event, searchActive: searchActive)
        if searchAction != .none { onInput?(.search(searchAction)); return }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "r" { onInput?(.navigate(.stay)) }
            else if event.charactersIgnoringModifiers?.lowercased() == "c" { copy(nil) }
            else { super.keyDown(with: event) }
            return
        }
        switch event.keyCode {
        case 120: onInput?(event.modifierFlags.contains(.shift) ? .toggleWrapType : .toggleWrap) // F2 / Shift-F2
        case 118: onInput?(.toggleMode) // F4
        case 53, 99, 109: onInput?(.close) // Escape / F3 / F10
        case 125: onInput?(.navigate(.scroll(1)))
        case 126: onInput?(.navigate(.scroll(-1)))
        case 121, 49: onInput?(.navigate(.scroll(visibleRows)))
        case 116: onInput?(.navigate(.scroll(-visibleRows)))
        case 115: onInput?(.navigate(.home))
        case 119: onInput?(.navigate(.end))
        case 123:
            if page?.mode == .text && !wrapsText {
                let step = event.modifierFlags.contains(.control) ? 20 : 1
                horizontalOffset = max(0, horizontalOffset - step)
                needsDisplay = true
            }
        case 124:
            if page?.mode == .text && !wrapsText {
                let step = event.modifierFlags.contains(.control) ? 20 : 1
                horizontalOffset = horizontalOffset > Int.max - step ? Int.max : horizontalOffset + step
                needsDisplay = true
            }
        default: break
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let action = DocumentSearchKeyAction.action(for: event, searchActive: searchActive)
        guard action != .none else { return super.performKeyEquivalent(with: event) }
        onInput?(.search(action))
        return true
    }
    override func mouseDown(with event: NSEvent) {
        isSelecting = false
        wordSelectedOnMouseDown = false
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let footer = NSRect(x: 0, y: bounds.height - TerminalTheme.lineHeight, width: bounds.width, height: TerminalTheme.lineHeight)
        if let slot = TerminalFunctionKeys.number(at: point, in: footer) {
            if slot == 2 { onInput?(.toggleWrap) }
            else if slot == 3 || slot == 10 { onInput?(.close) }
            else if slot == 4 { onInput?(.toggleMode) }
            else if slot == 7 { onInput?(.search(.focus)) }
            return
        }
        guard TerminalTextGeometry(bounds: bounds).contentRect.contains(point), let position = position(at: point) else { return }
        onSelectionChanged?()
        invalidateWordContinuation()
        if event.clickCount >= 2, isVisibleTextHit(point, position: position),
            let word = wordSelection(at: position) ?? leadingFragmentSelection(at: position) {
            anchor = word.start
            endpoint = word.end
            isSelecting = true
            wordSelectedOnMouseDown = true
            isWordSelection = true
            wordClickPosition = position
            if let page, page.mode == .text, wrapsText {
                let first = page.lines.first!
                let last = page.lines.last!
                let provisional = wordSelection(at: position) == nil
                let continuousToStart = position.row == 0 || (1...position.row).allSatisfy {
                    page.lines[$0 - 1].endOffset == page.lines[$0].offset
                }
                let touchesStart = word.start.row == 0 && word.start.column == 0
                let mayJoinStart = hasLeadingGraphemeFragment(before: word.start, page: page)
                let before = continuousToStart && (touchesStart || mayJoinStart) && first.offset > 0
                    ? first.offset : nil
                let after = ((word.end.row == page.lines.count - 1 && word.end.column == last.text.count)
                    || (provisional && provisionalMayReachPageEnd(page)))
                    && last.endOffset == page.endOffset
                    && (page.fileSize == nil || page.endOffset < page.fileSize!)
                    ? page.endOffset : nil
                if (before != nil || after != nil), let onWordContinuationNeeded {
                    isResolvingWord = true
                    let visibleWord = selectedText
                    var leadingText = first.text
                    if page.lines.count > 1 {
                        for row in 1..<page.lines.count {
                            guard page.lines[row - 1].endOffset == page.lines[row].offset else { break }
                            leadingText += page.lines[row].text
                        }
                    }
                    onWordContinuationNeeded(ViewerWordContinuationRequest(
                        token: wordSelectionToken, before: before,
                        beforeContext: before == nil ? "" : String(leadingText.first ?? visibleWord.first!),
                        after: after,
                        afterContext: after == nil ? "" : String(provisional
                            ? (leadingText.last ?? last.text.last!) : visibleWord.last!),
                        revision: page.revision, fileSize: page.fileSize))
                }
            }
            needsDisplay = true
            return
        }
        isWordSelection = false
        if !event.modifierFlags.contains(.shift) || anchor == nil { anchor = position }
        endpoint = position
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        if isWordSelection {
            onSelectionChanged?()
            invalidateWordContinuation()
        }
        wordSelectedOnMouseDown = false
        isWordSelection = false
        endpoint = position(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting else { return }
        if !wordSelectedOnMouseDown {
            endpoint = position(at: convert(event.locationInWindow, from: nil))
        }
        isSelecting = false
        wordSelectedOnMouseDown = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(TerminalTextGeometry(bounds: bounds).contentRect, cursor: .iBeam)
    }

    @objc func copy(_ sender: Any?) {
        if isResolvingWord {
            pendingCopyChangeCount = NSPasteboard.general.changeCount
            return
        }
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
    }

    func completeWordContinuation(_ continuation: ViewerWordContinuation,
                                  token: UInt64) {
        guard isWordSelection, token == wordSelectionToken else { return }
        if let click = wordClickPosition {
            guard let resolved = wordSelection(at: click, prefix: continuation.prefix) else {
                failWordContinuation(token: token)
                return
            }
            anchor = resolved.start
            endpoint = resolved.end
            wordPrefix = resolved.usesPrefix ? continuation.prefix : ""
            let reachesEnd = page.map { resolved.end.row == $0.lines.count - 1 &&
                resolved.end.column == $0.lines[resolved.end.row].text.count } ?? false
            wordSuffix = reachesEnd ? continuation.suffix : ""
            needsDisplay = true
        }
        isResolvingWord = false
        if let changeCount = pendingCopyChangeCount,
            NSPasteboard.general.changeCount == changeCount {
            pendingCopyChangeCount = nil
            copy(nil)
        } else {
            pendingCopyChangeCount = nil
        }
    }

    @discardableResult
    func failWordContinuation(token: UInt64) -> Bool {
        guard isWordSelection, token == wordSelectionToken else { return false }
        anchor = nil
        endpoint = nil
        isWordSelection = false
        wordClickPosition = nil
        isResolvingWord = false
        pendingCopyChangeCount = nil
        needsDisplay = true
        return true
    }

    private func invalidateWordContinuation() {
        wordSelectionToken &+= 1
        wordPrefix = ""
        wordSuffix = ""
        wordClickPosition = nil
        isResolvingWord = false
        pendingCopyChangeCount = nil
    }

    private func wordRange(at position: Position) -> Range<Int>? {
        guard let page, page.lines.indices.contains(position.row) else { return nil }
        return WordSelectionRange.characters(in: page.lines[position.row].text, at: position.column)
    }

    private func isVisibleTextHit(_ point: NSPoint, position: Position) -> Bool {
        guard let page, page.lines.indices.contains(position.row),
            point.y < CGFloat(min(visibleRows, page.lines.count) + 1) * TerminalTheme.lineHeight else {
            return false
        }
        let displayed = String(page.lines[position.row].text.dropFirst(horizontalOffset).prefix(visibleColumns))
        return !displayed.isEmpty && point.x <= 1 + textWidth(displayed)
    }

    private func wordSelection(at position: Position, prefix: String = "")
        -> (start: Position, end: Position, usesPrefix: Bool)? {
        guard let page else { return nil }
        guard page.mode == .text, wrapsText else {
            guard let word = wordRange(at: position) else { return nil }
            return (Position(row: position.row, column: word.lowerBound),
                Position(row: position.row, column: word.upperBound), false)
        }
        var first = position.row
        var last = position.row
        while first > 0 && page.lines[first - 1].endOffset == page.lines[first].offset {
            first -= 1
        }
        while last + 1 < page.lines.count && page.lines[last].endOffset == page.lines[last + 1].offset {
            last += 1
        }
        let context = first == 0 ? (prefix.last.map(String.init) ?? "") : ""
        let logicalText = context + (first...last).map { page.lines[$0].text }.joined()
        let contextLength = context.utf16.count
        let preceding = (first..<position.row).reduce(0) { $0 + page.lines[$1].text.utf16.count }
        let clicked = contextLength + preceding +
            String(page.lines[position.row].text.prefix(position.column)).utf16.count
        guard let word = WordSelectionRange.utf16(in: logicalText, at: clicked) else { return nil }
        let start = word.lowerBound < contextLength
            ? Position(row: first, column: 0)
            : self.position(atUTF16Offset: word.lowerBound - contextLength, rows: first...last,
                page: page, preferNextAtSeam: true)
        let end = self.position(atUTF16Offset: word.upperBound - contextLength, rows: first...last,
            page: page, preferNextAtSeam: false)
        return (start, end, word.lowerBound < contextLength)
    }

    private func position(atUTF16Offset offset: Int, rows: ClosedRange<Int>, page: ViewerPage,
                          preferNextAtSeam: Bool) -> Position {
        var cursor = 0
        for row in rows {
            let text = page.lines[row].text
            let width = text.utf16.count
            if offset < cursor + width || row == rows.upperBound ||
                (offset == cursor + width && !preferNextAtSeam) {
                let local = max(0, offset - cursor)
                var consumed = 0
                var column = 0
                for character in text {
                    if consumed >= local { break }
                    consumed += String(character).utf16.count
                    column += 1
                }
                return Position(row: row, column: column)
            }
            cursor += width
        }
        return Position(row: rows.upperBound, column: page.lines[rows.upperBound].text.count)
    }

    private func leadingFragmentSelection(at position: Position)
        -> (start: Position, end: Position, usesPrefix: Bool)? {
        guard let page, page.mode == .text, wrapsText, position.row == 0,
            page.lines[0].offset > 0, onWordContinuationNeeded != nil,
            position.column <= 1, let first = page.lines[0].text.first,
            first.unicodeScalars.allSatisfy(isGraphemeContinuation) else { return nil }
        return (Position(row: 0, column: 0), Position(row: 0, column: 1), false)
    }

    private func provisionalMayReachPageEnd(_ page: ViewerPage) -> Bool {
        guard !page.lines.isEmpty else { return false }
        if page.lines.count > 1 {
            for row in 1..<page.lines.count
                where page.lines[row - 1].endOffset != page.lines[row].offset {
                return false
            }
        }
        let text = page.lines.map(\.text).joined()
        return !text.isEmpty && text.allSatisfy { character in
            WordSelectionRange.isWord(character) ||
                character.unicodeScalars.allSatisfy(isGraphemeContinuation)
        }
    }

    private func hasLeadingGraphemeFragment(before position: Position, page: ViewerPage) -> Bool {
        guard position.row < page.lines.count else { return false }
        let preceding = (0..<position.row).map { page.lines[$0].text }.joined() +
            String(page.lines[position.row].text.prefix(position.column))
        return !preceding.isEmpty && preceding.unicodeScalars.allSatisfy(isGraphemeContinuation)
    }

    private func isGraphemeContinuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return CharacterSet.nonBaseCharacters.contains(scalar) || value == 0x200D ||
            (0xFE00...0xFE0F).contains(value) || (0x1F3FB...0x1F3FF).contains(value)
    }

    private func position(at point: NSPoint) -> Position? {
        guard let page, !page.lines.isEmpty else { return nil }
        let row = max(0, min(min(visibleRows, page.lines.count) - 1,
            Int(floor((point.y - TerminalTheme.lineHeight) / TerminalTheme.lineHeight))))
        let text = page.lines[row].text
        let offset = min(horizontalOffset, text.count)
        let displayed = String(text.dropFirst(offset))
        let x = max(0, point.x - 1)
        // Search composed-character boundaries using the same font as the renderer.
        // This keeps emoji and combining characters intact when hit testing.
        var low = 0
        var high = displayed.count
        while low < high {
            let middle = (low + high) / 2
            let left = textWidth(String(displayed.prefix(middle)))
            let right = textWidth(String(displayed.prefix(middle + 1)))
            if x < (left + right) / 2 { high = middle }
            else { low = middle + 1 }
        }
        return Position(row: row, column: offset + low)
    }

    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? TerminalTheme.lineHeight : 1)
        let steps = Int(scrollRemainder)
        if steps != 0 { onInput?(.navigate(.scroll(-steps))); scrollRemainder -= CGFloat(steps) }
    }
}
