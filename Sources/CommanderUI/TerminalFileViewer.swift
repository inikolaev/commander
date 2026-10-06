import AppKit
import FileManagerCore

@MainActor
final class TerminalFileViewer: TerminalSurfaceView {
    enum Input { case navigate(ViewerCommand), close, toggleMode }
    var onInput: ((Input) -> Void)?
    let path: String
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
    private var selection: (start: Position, end: Position)? {
        guard let anchor, let endpoint, anchor != endpoint else { return nil }
        return (min(anchor, endpoint), max(anchor, endpoint))
    }
    var selectedText: String {
        guard let page, let selection else { return "" }
        return (selection.start.row...selection.end.row).map { row in
            let text = page.lines[row].text
            let start = row == selection.start.row ? selection.start.column : 0
            let end = row == selection.end.row ? selection.end.column : text.count
            return String(text.dropFirst(start).prefix(end - start))
        }.joined(separator: "\n")
    }
    private var horizontalOffset = 0
    private var scrollRemainder: CGFloat = 0
    var onResize: (() -> Void)?
    var visibleRows: Int { min(200, TerminalTextGeometry(bounds: bounds).visibleRows) }

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Read-only file viewer: \(path)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(_ page: ViewerPage) {
        if self.page?.mode != page.mode { horizontalOffset = 0 }
        if self.page?.mode != page.mode || self.page?.offset != page.offset
            || self.page?.lines.map(\.text) != page.lines.map(\.text) {
            anchor = nil
            endpoint = nil
            isSelecting = false
        }
        self.page = page
        setAccessibilityValue(page.lines.map(\.text).joined(separator: "\n"))
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldRows = visibleRows
        super.setFrameSize(newSize)
        needsDisplay = true
        if oldRows != visibleRows { onResize?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let line = TerminalTheme.lineHeight
        let header = NSRect(x: 0, y: 0, width: bounds.width, height: line)
        let footer = NSRect(x: 0, y: bounds.height - line, width: bounds.width, height: line)
        TerminalTheme.selection.setFill()
        header.fill()
        let percent = page.map { $0.fileSize == 0 ? 100 : Int(Double($0.endOffset) / Double($0.fileSize) * 100) }
        let position = page.map { "Byte \($0.offset.formatted())/\($0.fileSize.formatted())" } ?? "Opening…"
        let encoding = page?.mode == .hex ? "HEX / ASCII" : "UTF-8"
        let status = "\(encoding)   \(position)   Col \(horizontalOffset + 1)   \(percent.map { "\($0)%" } ?? "")"
        let statusWidth = min(bounds.width * 0.76, ceil((status as NSString).size(withAttributes: [.font: TerminalTheme.font]).width))
        TerminalTheme.text(path, in: NSRect(x: 1, y: 0, width: max(0, bounds.width - statusWidth - 16), height: line), color: .black)
        TerminalTheme.text(status, in: NSRect(x: bounds.width - statusWidth - 2, y: 0,
            width: statusWidth, height: line), color: .black, alignment: .right)
        drawFunctionKeys(in: footer)
        NSGraphicsContext.saveGraphicsState()
        TerminalTextGeometry(bounds: bounds).contentRect.clip()
        if let page {
            for (index, row) in page.lines.prefix(visibleRows).enumerated() {
                let rect = NSRect(x: 1, y: CGFloat(index + 1) * line, width: bounds.width - 2, height: line)
                if rect.intersects(dirtyRect) {
                    let displayed = String(row.text.dropFirst(horizontalOffset))
                    TerminalTheme.text(displayed, in: rect, color: TerminalTheme.cyan, truncate: .byClipping)
                    if let selection, index >= selection.start.row, index <= selection.end.row {
                        let start = index == selection.start.row ? selection.start.column : 0
                        let end = index == selection.end.row ? selection.end.column : row.text.count
                        let left = rect.minX + textWidth(String(displayed.prefix(max(0, start - horizontalOffset))))
                        var right = rect.minX + textWidth(String(displayed.prefix(max(0, end - horizontalOffset))))
                        // Give selected line breaks a visible cell, including on empty lines.
                        if index < selection.end.row { right += textWidth(" ") }
                        if right > left {
                            NSGraphicsContext.saveGraphicsState()
                            NSRect(x: left, y: rect.minY, width: right - left, height: rect.height).clip()
                            TerminalTheme.selection.setFill()
                            rect.fill()
                            TerminalTheme.text(displayed, in: rect, color: .black, truncate: .byClipping)
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

    private func drawFunctionKeys(in footer: NSRect) {
        TerminalFunctionKeys.draw(in: footer, labels: [3: "Close", 4: page?.mode == .hex ? "Text" : "Hex", 10: "Quit"])
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "r" { onInput?(.navigate(.stay)) }
            else if event.charactersIgnoringModifiers?.lowercased() == "c" { copy(nil) }
            else { super.keyDown(with: event) }
            return
        }
        switch event.keyCode {
        case 118: onInput?(.toggleMode) // F4
        case 53, 99, 109: onInput?(.close) // Escape / F3 / F10
        case 125: onInput?(.navigate(.scroll(1)))
        case 126: onInput?(.navigate(.scroll(-1)))
        case 121, 49: onInput?(.navigate(.scroll(visibleRows)))
        case 116: onInput?(.navigate(.scroll(-visibleRows)))
        case 115: onInput?(.navigate(.home))
        case 119: onInput?(.navigate(.end))
        case 123: horizontalOffset = max(0, horizontalOffset - 8); needsDisplay = true
        case 124: horizontalOffset = min(32768, horizontalOffset + 8); needsDisplay = true
        default: break
        }
    }
    override func mouseDown(with event: NSEvent) {
        isSelecting = false
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let footer = NSRect(x: 0, y: bounds.height - TerminalTheme.lineHeight, width: bounds.width, height: TerminalTheme.lineHeight)
        if let slot = TerminalFunctionKeys.number(at: point, in: footer) {
            if slot == 3 || slot == 10 { onInput?(.close) }
            else if slot == 4 { onInput?(.toggleMode) }
            return
        }
        guard TerminalTextGeometry(bounds: bounds).contentRect.contains(point), let position = position(at: point) else { return }
        if !event.modifierFlags.contains(.shift) || anchor == nil { anchor = position }
        endpoint = position
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting else { return }
        endpoint = position(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelecting else { return }
        endpoint = position(at: convert(event.locationInWindow, from: nil))
        isSelecting = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(TerminalTextGeometry(bounds: bounds).contentRect, cursor: .iBeam)
    }

    @objc func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
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
