import AppKit

/// Shared ten-slot footer for the file panels and viewer.
@MainActor
enum TerminalFunctionKeys {
    private static let labelLeadingInset: CGFloat = 4
    private static let digitCellCount: CGFloat = 11 // 1...9 plus the two digits in 10

    static func draw(in rect: NSRect, labels: [Int: String]) {
        NSColor.black.setFill()
        rect.fill()

        let digitCellWidth = TerminalTheme.cellWidth
        let totalNumberWidth = digitCellCount * digitCellWidth
        let buttonWidth = max(0, (rect.width - totalNumberWidth) / 10)

        var x = rect.minX
        for number in 1...10 {
            for digit in String(number) {
                let digitRect = NSRect(
                    x: x,
                    y: rect.minY,
                    width: digitCellWidth,
                    height: rect.height
                )
                TerminalTheme.text(
                    String(digit),
                    in: digitRect,
                    color: TerminalTheme.white,
                    alignment: .center
                )
                x += digitCellWidth
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

        let digitCellWidth = TerminalTheme.cellWidth
        let totalNumberWidth = digitCellCount * digitCellWidth
        let buttonWidth = max(0, (rect.width - totalNumberWidth) / 10)

        var x = rect.minX
        for number in 1...10 {
            let numberWidth = CGFloat(String(number).count) * digitCellWidth
            let keyWidth = numberWidth + buttonWidth
            if point.x >= x, point.x < x + keyWidth { return number }
            x += keyWidth
        }
        return 10
    }
}
