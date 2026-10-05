import AppKit

/// Shared ten-slot footer for the file panels and viewer.
@MainActor
enum TerminalFunctionKeys {
    private static let labelLeadingInset: CGFloat = 4

    static func draw(in rect: NSRect, labels: [Int: String]) {
        NSColor.black.setFill()
        rect.fill()
        let width = rect.width / 10
        for number in 1...10 {
            let x = rect.minX + CGFloat(number - 1) * width
            let numberWidth = ceil(("\(number)" as NSString).size(withAttributes: [.font: TerminalTheme.font]).width)
            TerminalTheme.text("\(number)", in: NSRect(x: x, y: rect.minY, width: numberWidth, height: rect.height), color: TerminalTheme.white)
            // Keep the 3 pt black separator between keys, but do not leave a
            // trailing black block after the final F10 label.
            let trailingGap: CGFloat = number == 10 ? 0 : 3
            let button = NSRect(x: x + numberWidth, y: rect.minY,
                width: max(0, width - numberWidth - trailingGap), height: rect.height)
            TerminalTheme.selection.setFill()
            button.fill()
            let labelRect = NSRect(x: button.minX + labelLeadingInset, y: button.minY,
                width: max(0, button.width - labelLeadingInset), height: button.height)
            TerminalTheme.text(labels[number] ?? "", in: labelRect, color: .black)
        }
    }

    static func number(at point: NSPoint, in rect: NSRect) -> Int? {
        guard rect.width > 0, rect.contains(point) else { return nil }
        return min(10, Int((point.x - rect.minX) / (rect.width / 10)) + 1)
    }
}
