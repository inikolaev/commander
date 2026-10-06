import AppKit
import FileManagerCore

/// Geometry shared by painting and hit testing. Coordinates start at the top left.
struct PaneGeometry {
    let bounds: NSRect
    let lineHeight: CGFloat
    var listTop: CGFloat { lineHeight * 2 }
    var listBottomPadding: CGFloat { 1 }
    var rowsPerColumn: Int { max(1, Int((separatorY - listTop - listBottomPadding) / lineHeight)) }
    var columnWidth: CGFloat { max(1, (bounds.width - 12) / 2) }
    var separatorY: CGFloat { bounds.height - lineHeight * 2.5 }

    func cell(column: Int, row: Int) -> NSRect {
        NSRect(x: 6 + CGFloat(column) * columnWidth, y: listTop + CGFloat(row) * lineHeight,
               width: columnWidth - 1, height: lineHeight)
    }

    func position(at point: NSPoint) -> (column: Int, row: Int)? {
        guard point.x >= 6, point.x < bounds.width - 6, point.y >= listTop else { return nil }
        let column = Int((point.x - 6) / columnWidth)
        let row = Int((point.y - listTop) / lineHeight)
        guard column < 2, row < rowsPerColumn else { return nil }
        return (column, row)
    }
}

enum PaneInput {
    case toggleMark
    case extendSelection(Int), endRangeSelection
    case activate, switchPane, matchDirectory, open, parent, copy, move, rename, delete, viewFile, editFile, quit, createDirectory
    case locations(Int)
    case select(Int)
}

/// A single drawing surface, with no NSTableView, NSScrollView, or native row widgets.
/// The controller owns selection; this view owns only viewport and input presentation.
@MainActor
final class TerminalPaneView: NSView {
    var onInput: ((PaneInput) -> Void)?
    private(set) var state = PaneState(directory: URL(fileURLWithPath: "/"))
    private(set) var viewport = ColumnViewport()
    var isActive = false { didSet { needsDisplay = true } }
    private var status = ""
    private var isError = false
    private var prefix = ""
    private var lastTypedAt: TimeInterval = 0
    private var scrollRemainder: CGFloat = 0
    private let paneName: String

    init(name: String) {
        paneName = name
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(name)
        setAccessibilityHelp("Use Space to mark entries, arrows to move, Tab to switch panes, Return to open, and Delete to go to the parent folder.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    var geometry: PaneGeometry { PaneGeometry(bounds: bounds, lineHeight: TerminalTheme.lineHeight) }

    func update(state: PaneState, status: String, isError: Bool = false) {
        if self.state.directory != state.directory { prefix = ""; viewport = ColumnViewport() }
        self.state = state
        self.status = status
        self.isError = isError
        updateViewport()
        toolTip = isError ? status : nil
        setAccessibilityValue("\(state.directory.path). \(state.selectedRow?.name ?? "Empty folder"). \(status)")
        needsDisplay = true
    }

    private func updateViewport() {
        viewport.resize(rows: geometry.rowsPerColumn, selectedIndex: state.selectedIndex, itemCount: state.rows.count)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateViewport()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        onInput?(.activate)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let g = geometry
        let line = TerminalTheme.lineHeight
        TerminalTheme.cyan.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2.5, dy: line / 2))
        border.lineWidth = 1
        border.stroke()
        let inner = NSBezierPath(rect: bounds.insetBy(dx: 4.5, dy: line / 2 + 2))
        inner.lineWidth = 1
        inner.stroke()
        let separators = NSBezierPath()
        separators.move(to: NSPoint(x: bounds.midX, y: line))
        separators.line(to: NSPoint(x: bounds.midX, y: g.separatorY))
        separators.move(to: NSPoint(x: 5, y: g.separatorY))
        separators.line(to: NSPoint(x: bounds.width - 5, y: g.separatorY))
        separators.stroke()

        let path = state.directory.path
        let textWidth = (path as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
        // Text layout can discard trailing spaces; use geometric padding instead.
        let titlePadding: CGFloat = 8
        let pathWidth = min(bounds.width - 40, ceil(textWidth) + titlePadding * 2)
        let pathRect = NSRect(x: (bounds.width - pathWidth) / 2, y: 0, width: pathWidth, height: line)
        (isActive ? TerminalTheme.selection : TerminalTheme.background).setFill()
        pathRect.fill()
        TerminalTheme.text(path, in: pathRect.insetBy(dx: titlePadding, dy: 0), color: isActive ? .black : TerminalTheme.cyan, alignment: .center)

        for column in 0..<2 {
            TerminalTheme.text("Name", in: NSRect(x: 6 + CGFloat(column) * g.columnWidth,
                y: line, width: g.columnWidth, height: line), color: TerminalTheme.yellow, alignment: .center)
            for row in 0..<g.rowsPerColumn {
                guard let index = viewport.index(column: column, row: row, itemCount: state.rows.count) else { break }
                let entry = state.rows[index]
                let rect = g.cell(column: column, row: row)
                guard rect.intersects(dirtyRect) else { continue }
                let selected = state.selectedIndex == index && isActive
                if selected { TerminalTheme.selection.setFill(); rect.fill() }
                let isLink = if case .entry(let file) = entry { file.isSymbolicLink } else { false }
                let cloud = if case .entry(let file) = entry { file.cloudStatus } else { CloudFileStatus.none }
                let color = FileColorScheme.color(for: entry, isSelected: selected, isMarked: state.isMarked(entry))
                var nameRect = rect.insetBy(dx: 2, dy: 0)
                if CloudFileAppearance.symbol(for: cloud) != nil {
                    let iconRect = NSRect(x: nameRect.maxX - 18, y: rect.midY - 7, width: 16, height: 14)
                    CloudFileAppearance.drawIcon(for: cloud, in: iconRect, color: color)
                    nameRect.size.width = max(0, nameRect.width - 22)
                }
                TerminalTheme.text(entry.name + (isLink ? " ↗" : ""), in: nameRect, color: color)
            }
        }

        let footerBottom = bounds.height - line / 2 - 2
        PaneFooter.draw(state: state, in: NSRect(x: 8, y: g.separatorY,
            width: bounds.width - 16, height: max(0, footerBottom - g.separatorY)))
        let summaryWidth = min(bounds.width - 28, (status as NSString).size(withAttributes: [.font: TerminalTheme.font]).width + 16)
        let summary = NSRect(x: (bounds.width - summaryWidth) / 2, y: bounds.height - line, width: summaryWidth, height: line)
        TerminalTheme.background.setFill()
        summary.fill()
        TerminalTheme.text(status, in: summary, color: isError ? TerminalTheme.yellow : TerminalTheme.cyan, alignment: .center)
    }

    private func move(_ delta: Int, extending: Bool = false) {
        if let index = viewport.movedIndex(from: state.selectedIndex, by: delta, itemCount: state.rows.count) {
            onInput?(extending ? .extendSelection(index) : .select(index))
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            onInput?(.matchDirectory)
            return
        }
        if modifiers == .option, [122, 120].contains(event.keyCode) {
            onInput?(.locations(event.keyCode == 122 ? 0 : 1))
            return
        }
        if modifiers == .command, let key = event.charactersIgnoringModifiers, ["1", "2"].contains(key) {
            onInput?(.locations(key == "1" ? 0 : 1))
            return
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.shift), [99, 118, 96, 97, 98, 100, 109].contains(event.keyCode) {
            if event.keyCode == 97 { onInput?(.rename) }
            return
        }
        switch event.keyCode {
        case 49: prefix = ""; if !event.isARepeat { onInput?(.toggleMark) }
        case 109: onInput?(.quit) // F10
        case 99: onInput?(.viewFile) // F3
        case 118: onInput?(.editFile) // F4
        case 96: onInput?(.copy) // F5
        case 97: onInput?(.move) // F6
        case 98: onInput?(.createDirectory) // F7
        case 100: onInput?(.delete) // F8
        case 48: onInput?(.switchPane)
        case 36, 76: onInput?(.open)
        case 51: onInput?(.parent)
        case 125: move(1, extending: event.modifierFlags.contains(.shift))
        case 126: move(-1, extending: event.modifierFlags.contains(.shift))
        case 123: move(-viewport.rowsPerColumn, extending: event.modifierFlags.contains(.shift))
        case 124: move(viewport.rowsPerColumn, extending: event.modifierFlags.contains(.shift))
        case 116: move(-viewport.capacity)
        case 121: move(viewport.capacity)
        case 115: if !state.rows.isEmpty { onInput?(.select(0)) }
        case 119: if !state.rows.isEmpty { onInput?(.select(state.rows.count - 1)) }
        case 53: prefix = ""
        default:
            guard let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) else { return }
            if event.timestamp - lastTypedAt > 1 { prefix = "" }
            lastTypedAt = event.timestamp
            prefix += text
            if let index = state.rows.firstIndex(where: { $0.name.lowercased().hasPrefix(prefix.lowercased()) }) {
                onInput?(.select(index))
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.shift) { onInput?(.endRangeSelection) }
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let position = geometry.position(at: point),
              let index = viewport.index(column: position.column, row: position.row, itemCount: state.rows.count) else { return }
        onInput?(.select(index))
        if event.clickCount == 2 { onInput?(.open) }
    }

    override func scrollWheel(with event: NSEvent) {
        window?.makeFirstResponder(self)
        scrollRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? TerminalTheme.lineHeight : 1)
        let steps = Int(scrollRemainder)
        if steps != 0 { move(-steps); scrollRemainder -= CGFloat(steps) }
    }
}
