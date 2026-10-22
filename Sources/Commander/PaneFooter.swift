import AppKit
import FileManagerCore

/// Fixed metadata columns anchor to the right; long names truncate independently.
@MainActor
enum PaneFooter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM/yy HH:mm"
        return formatter
    }()

    static func draw(state: PaneState, in rect: NSRect) {
        // Center a shared font line box within the actual footer borders.
        let textHeight = ("Ag" as NSString).size(withAttributes: [.font: TerminalTheme.font]).height
        let rect = NSRect(x: rect.minX, y: rect.midY - textHeight / 2,
            width: rect.width, height: textHeight)
        guard let row = state.selectedRow else {
            TerminalTheme.text("Empty folder", in: rect)
            return
        }
        let size: String
        let modified: Date?
        switch row {
        case .parent:
            size = "Up"
            modified = state.directoryModified
        case .entry(let entry):
            size = entry.isDirectory ? "<DIR>" : entry.size.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—"
            modified = entry.modified
        }
        let cellWidth = ("0" as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
        let dateWidth = ceil(cellWidth * 14)
        let sizeWidth = ceil(cellWidth * 8)
        let gap = ceil(cellWidth)
        let dateRect = NSRect(x: rect.maxX - dateWidth, y: rect.minY, width: dateWidth, height: rect.height)
        let sizeRect = NSRect(x: dateRect.minX - gap - sizeWidth, y: rect.minY, width: sizeWidth, height: rect.height)
        var nameRect = NSRect(x: rect.minX, y: rect.minY,
            width: max(0, sizeRect.minX - gap - rect.minX), height: rect.height)
        if case .entry(let entry) = row,
           CloudFileAppearance.symbol(for: entry.cloudStatus) != nil, nameRect.width >= 22 {
            // A compact icon before the fixed metadata columns leaves room for the name.
            let cloudRect = NSRect(x: nameRect.maxX - 18, y: rect.midY - 7, width: 16, height: 14)
            nameRect.size.width -= 22
            CloudFileAppearance.drawIcon(for: entry.cloudStatus, in: cloudRect, color: TerminalTheme.accent)
        }
        TerminalTheme.text(row.name, in: nameRect)
        TerminalTheme.text(size, in: sizeRect, alignment: .right)
        TerminalTheme.text(modified.map(dateFormatter.string(from:)) ?? "—", in: dateRect, alignment: .right)
    }
}
