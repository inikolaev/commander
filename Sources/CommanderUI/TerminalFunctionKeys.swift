import AppKit

/// Shared ten-slot footer for the file panels and viewer.
@MainActor
enum TerminalFunctionKeys {
    private static let labelLeadingInset: CGFloat = 4
    private static let digitHorizontalPadding: CGFloat = 2

    static func draw(in rect: NSRect, labels: [Int: String]) {
        NSColor.black.setFill()
        rect.fill()

        let slotWidth = rect.width / 10
        let digitWidth = ceil(("0" as NSString).size(
            withAttributes: [.font: TerminalTheme.font]
        ).width)
        let digitCellWidth = digitWidth + digitHorizontalPadding * 2

        for number in 1...10 {
            let x = rect.minX + CGFloat(number - 1) * slotWidth
            let digits = Array(String(number))
            let numberWidth = CGFloat(digits.count) * digitCellWidth

            for (index, digit) in digits.enumerated() {
                let digitRect = NSRect(
                    x: x + CGFloat(index) * digitCellWidth,
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
            }

            // The next slot's black number cells are the separator between
            // function keys. Do not add another trailing black gap here: it would
            // visually merge with the next number block and make that block wider.
            let button = NSRect(
                x: x + numberWidth,
                y: rect.minY,
                width: max(0, slotWidth - numberWidth),
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
        }
    }

    static func number(at point: NSPoint, in rect: NSRect) -> Int? {
        guard rect.width > 0, rect.contains(point) else { return nil }
        return min(10, Int((point.x - rect.minX) / (rect.width / 10)) + 1)
    }
}
