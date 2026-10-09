import AppKit
import SyntaxCore

/// All terminal styling is centralized; the renderer has no dependence on system table styles.
@MainActor
enum TerminalTheme {
    static let background = NSColor(hex: 0x001450)
    static let cyan = NSColor(hex: 0x39C7D8)
    static let selection = NSColor(hex: 0x0099A1)
    static let white = NSColor(hex: 0xBCC8D8)
    static let yellow = NSColor(hex: 0xF2E333)

    // Syntax colors intentionally vary in both hue and luminance so token
    // classes remain distinct against the dark terminal-blue background.
    static let syntaxProperty = NSColor(hex: 0xFABA3D)
    static let syntaxString = NSColor(hex: 0x7DD787)
    static let syntaxNumber = NSColor(hex: 0xF56F3F)
    static let syntaxConstant = NSColor(hex: 0xB788EE)
    static let syntaxComment = NSColor(hex: 0x596E80)

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
