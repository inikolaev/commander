import AppKit

/// Shared text viewport between the one-line header and function-key footer.
@MainActor
struct TerminalTextGeometry {
    let bounds: NSRect

    var contentRect: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY + TerminalTheme.lineHeight,
               width: bounds.width, height: max(0, bounds.height - 2 * TerminalTheme.lineHeight))
    }

    var visibleRows: Int {
        // The final row needs room for its text, but not the trailing line spacing.
        let textHeight = ceil(("Mg" as NSString).size(withAttributes: [.font: TerminalTheme.font]).height)
        guard contentRect.height >= textHeight else { return 1 }
        return 1 + Int((contentRect.height - textHeight) / TerminalTheme.lineHeight)
    }
}
