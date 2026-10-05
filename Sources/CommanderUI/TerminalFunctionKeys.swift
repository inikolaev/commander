import AppKit

/// Shared ten-slot footer for the file panels and viewer.
@MainActor
enum TerminalFunctionKeys {
    private static let labelLeadingInset: CGFloat = 4
    private static let keyCount: CGFloat = 10
    private static let digitCellCount: CGFloat = 11 // 1...9 plus the two digits in 10
    private static let leadingGapCellCount: CGFloat = 10 // one black cell before every key

    static func draw(in rect: NSRect, labels: [Int: String]) {
        NSColor.black.setFill()
        rect.fill()

        let cellWidth = TerminalTheme.cellWidth
        let fixedBlackWidth = (digitCellCount + leadingGapCellCount) * cellWidth
        let buttonWidth = max(0, (rect.width - fixedBlackWidth) / keyCount)

        var x = rect.minX
        for number in 1...10 {
            // Retro FAR-style spacing: reserve one black character cell before
            // every key, including F1. The leading F1 gap also absorbs the
            // rounded bottom-left corner without clipping the "1" digit cell.
            x += cellWidth

            for digit in String(number) {
                let digitRect = NSRect(
                    x: x,
                    y: rect.minY,
                    width: cellWidth,
                    height: rect.height
                )
                TerminalTheme.text(
                    String(digit),
                    in: digitRect,
                    color: TerminalTheme.white,
                    alignment: .center
                )
                x += cellWidth
            }

            let button = NSRect(
                x: x,
                y: rect.minY,
                width: buttonWidth,
                height: rect.height
            )
            TerminalTheme.selection.setFill()
            button.fill()

            let labelRect = NSRect(
                x: button.minX + labelLeadingInset,
                y: button.minY,
                width: max(0, button.width - labelLeadingInset),
                height: button.height
            )
            TerminalTheme.text(labels[number] ?? "", in: labelRect, color: .black)
            x += buttonWidth
        }
    }

    static func number(at point: NSPoint, in rect: NSRect) -> Int? {
        guard rect.width > 0, rect.contains(point) else { return nil }

        let cellWidth = TerminalTheme.cellWidth
        let fixedBlackWidth = (digitCellCount + leadingGapCellCount) * cellWidth
        let buttonWidth = max(0, (rect.width - fixedBlackWidth) / keyCount)

        var x = rect.minX
        for number in 1...10 {
            let keyStart = x
            let numberWidth = CGFloat(String(number).count) * cellWidth
            let keyWidth = cellWidth + numberWidth + buttonWidth
            if point.x >= keyStart, point.x < keyStart + keyWidth { return number }
            x += keyWidth
        }
        return 10
    }
}
