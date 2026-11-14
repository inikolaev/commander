import AppKit

/// Shared frame and heading for in-window terminal dialogs. Subclasses supply
/// their own content, size, and keyboard behavior.
@MainActor
class TerminalDialogView: NSView {
    private static let titleSideGap: CGFloat = 8

    override var isFlipped: Bool { true }

    func drawDialogFrame(panel: NSRect, outerBorder: NSRect, title: String,
                         titleFont: NSFont, titleHeight: CGFloat = 20,
                         background: NSColor, foreground: NSColor) {
        background.setFill()
        panel.fill()
        foreground.setStroke()
        let innerBorder = outerBorder.insetBy(dx: 3, dy: 3)
        for borderRect in [outerBorder, innerBorder] {
            let border = NSBezierPath(rect: borderRect)
            border.lineWidth = 1
            border.stroke()
        }

        let heading = title.trimmingCharacters(in: .whitespaces)
        let textWidth = ceil((heading as NSString).size(withAttributes: [.font: titleFont]).width)
        let borderMidY = (outerBorder.minY + innerBorder.minY) / 2
        let textRect = NSRect(x: panel.midX - textWidth / 2, y: borderMidY - titleHeight / 2,
                              width: textWidth, height: titleHeight)
        background.setFill()
        textRect.insetBy(dx: -Self.titleSideGap, dy: 0).fill()
        TerminalTheme.text(heading, in: textRect,
                           color: foreground, alignment: .center, font: titleFont)
    }
}
