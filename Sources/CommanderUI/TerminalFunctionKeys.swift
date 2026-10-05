import AppKit

/// Shared ten-slot footer for the file panels and viewer.
@MainActor
enum TerminalFunctionKeys {
    private static let labelLeadingInset: CGFloat = 4
    private static let digitHorizontalPadding: CGFloat = 2

    static func draw(in rect: NSRect, labels: [Int: String]) {
        let digitWidth = ceil(("0" as NSString).size(
            withAttributes: [.font: TerminalTheme.font]
        ).width)
        let digitCellWidth = ceil(digitWidth + digitHorizontalPadding * 2)

        for number in 1...10 {
            // Snap every slot boundary to whole points. This keeps the visible
            // number-cell widths identical instead of letting fractional tenth
            // widths rasterize differently from one slot to the next.
            let slotMinX = round(rect.minX + CGFloat(number - 1) * rect.width / 10)
            let slotMaxX = round(rect.minX + CGFloat(number) * rect.width / 10)
            let slotWidth = max(0, slotMaxX - slotMinX)

            let digits = Array(String(number))
            let numberWidth = CGFloat(digits.count) * digitCellWidth

            for (index, digit) in digits.enumerated() {
                let digitRect = NSRect(
                    x: slotMinX + CGFloat(index) * digitCellWidth,
                    y: rect.minY,
                    width: digitCellWidth,
                    height: rect.height
                )
                NSColor.black.setFill()
                digitRect.fill()
                TerminalTheme.text(
                    String(digit),
                    in: digitRect,
                    color: TerminalTheme.white,
                    alignment: .center
                )
            }

            let button = NSRect(
                x: slotMinX + numberWidth,
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
