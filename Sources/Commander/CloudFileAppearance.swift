import AppKit
import FileManagerCore

@MainActor
enum CloudFileAppearance {
    static func label(for status: CloudFileStatus) -> String? {
        switch status {
        case .none: nil
        case .unknown: "iCloud · Status unknown"
        case .notDownloaded: "iCloud · Not downloaded"
        case .downloading: "iCloud · Downloading…"
        case .downloaded: "iCloud · Downloaded"
        }
    }

    static func symbol(for status: CloudFileStatus) -> String? {
        switch status {
        case .notDownloaded: "icloud.and.arrow.down"
        case .downloading: "icloud.and.arrow.down"
        default: nil
        }
    }

    static func drawIcon(for status: CloudFileStatus, in rect: NSRect, color: NSColor) {
        guard let symbol = symbol(for: status),
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label(for: status))?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))?
                .withSymbolConfiguration(.init(paletteColors: [color])) else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
            width: size.width, height: size.height), from: .zero, operation: .sourceOver,
            fraction: 1, respectFlipped: true, hints: nil)
    }
}
