import AppKit
import SyntaxCore

/// All terminal styling is centralized; renderers depend only on semantic roles.
@MainActor
enum TerminalTheme {
    private struct Palette {
        let windowBackground: NSColor
        let background: NSColor
        let accent: NSColor
        let selection: NSColor
        let primaryText: NSColor
        let heading: NSColor
        let warning: NSColor
        let syntaxProperty: NSColor
        let syntaxString: NSColor
        let syntaxNumber: NSColor
        let syntaxConstant: NSColor
        let syntaxComment: NSColor
        let hiddenFile: NSColor
        let archiveFile: NSColor
        let executableFile: NSColor
        let markedFile: NSColor
        let keyBarBackground: NSColor
        let keyBarText: NSColor
        let keyBarButton: NSColor
        let keyBarButtonText: NSColor
        let dangerText: NSColor
        let contrastText: NSColor
    }

    private static let dark = Palette(
        windowBackground: NSColor(hex: 0x001450),
        background: NSColor(hex: 0x001450),
        accent: NSColor(hex: 0x39C7D8),
        selection: NSColor(hex: 0x0099A1),
        primaryText: NSColor(hex: 0xBCC8D8),
        heading: NSColor(hex: 0xF2E333),
        warning: NSColor(hex: 0xF2E333),
        syntaxProperty: NSColor(hex: 0xFABA3D),
        syntaxString: NSColor(hex: 0x7DD787),
        syntaxNumber: NSColor(hex: 0xF56F3F),
        syntaxConstant: NSColor(hex: 0xB788EE),
        syntaxComment: NSColor(hex: 0x596E80),
        hiddenFile: NSColor(hex: 0x59759B),
        archiveFile: NSColor(hex: 0xFF66CC),
        executableFile: NSColor(hex: 0x40E65A),
        markedFile: NSColor(hex: 0xF2E333),
        keyBarBackground: .black,
        keyBarText: NSColor(hex: 0xBCC8D8),
        keyBarButton: NSColor(hex: 0x0099A1),
        keyBarButtonText: .black,
        dangerText: NSColor(hex: 0xBCC8D8),
        contrastText: .black
    )

    // Soft Sky: a low-glare light-blue palette with restrained, warm syntax colors.
    private static let light = Palette(
        windowBackground: NSColor(hex: 0xDCEAF4),
        background: NSColor(hex: 0xEAF4FB),
        accent: NSColor(hex: 0x4C8FB6),
        selection: NSColor(hex: 0xA8D7E8),
        primaryText: NSColor(hex: 0x2F4151),
        heading: NSColor(hex: 0x326E93),
        warning: NSColor(hex: 0x9A6A16),
        syntaxProperty: NSColor(hex: 0xB06A2E),
        syntaxString: NSColor(hex: 0x3E7A5E),
        syntaxNumber: NSColor(hex: 0xC45B41),
        syntaxConstant: NSColor(hex: 0x7B66B2),
        syntaxComment: NSColor(hex: 0x5B6E7D),
        hiddenFile: NSColor(hex: 0x718493),
        archiveFile: NSColor(hex: 0x9B507D),
        executableFile: NSColor(hex: 0x347A52),
        markedFile: NSColor(hex: 0x9A6A16),
        keyBarBackground: NSColor(hex: 0xD7E8F2),
        keyBarText: NSColor(hex: 0x2F4151),
        keyBarButton: NSColor(hex: 0xA8D7E8),
        keyBarButtonText: NSColor(hex: 0x2F4151),
        dangerText: NSColor(hex: 0xF3F6F8),
        contrastText: NSColor(hex: 0x20303D)
    )

    private static var palette: Palette {
        CommanderAppearancePreference.isDark ? dark : light
    }

    static var windowBackground: NSColor { palette.windowBackground }
    static var background: NSColor { palette.background }
    static var accent: NSColor { palette.accent }
    static var selection: NSColor { palette.selection }
    static var primaryText: NSColor { palette.primaryText }
    static var heading: NSColor { palette.heading }
    static var warning: NSColor { palette.warning }
    static var syntaxProperty: NSColor { palette.syntaxProperty }
    static var syntaxString: NSColor { palette.syntaxString }
    static var syntaxNumber: NSColor { palette.syntaxNumber }
    static var syntaxConstant: NSColor { palette.syntaxConstant }
    static var syntaxComment: NSColor { palette.syntaxComment }
    static var hiddenFile: NSColor { palette.hiddenFile }
    static var archiveFile: NSColor { palette.archiveFile }
    static var executableFile: NSColor { palette.executableFile }
    static var markedFile: NSColor { palette.markedFile }
    static var keyBarBackground: NSColor { palette.keyBarBackground }
    static var keyBarText: NSColor { palette.keyBarText }
    static var keyBarButton: NSColor { palette.keyBarButton }
    static var keyBarButtonText: NSColor { palette.keyBarButtonText }
    static var dangerText: NSColor { palette.dangerText }
    static var contrastText: NSColor { palette.contrastText }

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

    static func text(_ string: String, in rect: NSRect, color: NSColor? = nil,
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
            .font: font, .foregroundColor: color ?? accent, .paragraphStyle: paragraph,
        ])
        NSGraphicsContext.restoreGraphicsState()
    }
}
