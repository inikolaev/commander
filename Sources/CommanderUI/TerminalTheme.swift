import AppKit
import SyntaxCore

/// All terminal styling is centralized; the renderer has no dependence on system table styles.
@MainActor
enum TerminalTheme {
    static let background = NSColor(srgbRed: 0, green: 0, blue: 0.48, alpha: 1)
    static let cyan = NSColor(srgbRed: 0, green: 0.76, blue: 0.79, alpha: 1)
    static let selection = NSColor(srgbRed: 0, green: 0.60, blue: 0.63, alpha: 1)
    static let white = NSColor(srgbRed: 0.84, green: 0.86, blue: 0.89, alpha: 1)
    static let yellow = NSColor(srgbRed: 0.95, green: 0.89, blue: 0.20, alpha: 1)
    // Syntax colors intentionally vary in both hue and luminance so token
    // classes remain distinct against the saturated terminal-blue background.
    static let syntaxProperty = NSColor(srgbRed: 0.96, green: 0.78, blue: 0.42, alpha: 1)
    static let syntaxString = NSColor(srgbRed: 0.60, green: 0.78, blue: 0.61, alpha: 1)
    static let syntaxNumber = NSColor(srgbRed: 0.94, green: 0.58, blue: 0.38, alpha: 1)
    static let syntaxConstant = NSColor(srgbRed: 0.79, green: 0.62, blue: 0.88, alpha: 1)
    static let syntaxComment = NSColor(srgbRed: 0.46, green: 0.55, blue: 0.60, alpha: 1)
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    static let cellAdvance: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width
    static let cellWidth: CGFloat = ceil(cellAdvance)
    static let lineHeight: CGFloat = 18

    static func syntaxColor(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .property: syntaxProperty
        case .string: syntaxString
        case .number: syntaxNumber
        case .constant: syntaxConstant
        case .comment: syntaxComment
        }
    }

    static func text(_ string: String, in rect: NSRect, color: NSColor = cyan,
                     alignment: NSTextAlignment = .left, truncate: NSLineBreakMode = .byTruncatingMiddle) {
        guard rect.width > 0, rect.height > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = truncate
        // AppKit otherwise compresses long rows before truncating, breaking
        // monospaced alignment between filenames of different lengths.
        paragraph.allowsDefaultTighteningForTruncation = false
        // Filenames may contain newlines and tabs. Keep every entry on its own visual row.
        let safe = string.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "�" : String($0) }.joined()
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        (safe as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }
}
