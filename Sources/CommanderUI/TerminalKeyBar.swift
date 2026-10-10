import AppKit

@MainActor
final class TerminalKeyBar: NSView {
    enum Command: Int, CaseIterable {
        case viewFile = 3, editFile = 4, copy = 5, move = 6, createDirectory = 7, delete = 8, quit = 10, leftLocations = 101, rightLocations = 102, rename = 106, createFile = 104
        var label: String {
            switch self {
            case .leftLocations: "Left"
            case .rightLocations: "Right"
            case .viewFile: "View"
            case .editFile: "Edit"
            case .createFile: "New file"
            case .copy: "Copy"
            case .move: "Move"
            case .rename: "Rename"
            case .createDirectory: "Mkdir"
            case .delete: "Delete"
            case .quit: "Quit"
            }
        }
    }

    private let cornerRadius: CGFloat = 0

    var shiftPressed = false { didSet { needsDisplay = true } }
    var optionPressed = false { didSet { needsDisplay = true } }

    static func command(number: Int, shift: Bool, option: Bool = false) -> Command? {
        if option {
            guard !shift else { return nil }
            return number == 1 ? .leftLocations : number == 2 ? .rightLocations : nil
        }
        return shift ? (number == 4 ? .createFile : number == 6 ? .rename : nil) : Command(rawValue: number)
    }

    var labels: [Int: String] {
        Dictionary(uniqueKeysWithValues: (1...10).compactMap { number in
            Self.command(number: number, shift: shiftPressed, option: optionPressed).map { (number, $0.label) }
        })
    }

    var onCommand: ((Command) -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if cornerRadius > 0 {
            NSGraphicsContext.saveGraphicsState()
            roundedPath(in: bounds).addClip()
            TerminalFunctionKeys.draw(in: bounds, labels: labels)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            TerminalFunctionKeys.draw(in: bounds, labels: labels)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard cornerRadius == 0 || roundedPath(in: bounds).contains(point) else { return }
        if let number = TerminalFunctionKeys.number(at: point, in: bounds),
           let command = Self.command(
               number: number,
               shift: event.modifierFlags.contains(.shift),
               option: event.modifierFlags.contains(.option)
           ) {
            onCommand?(command)
        }
    }

    private func roundedPath(in rect: NSRect) -> NSBezierPath {
        let radius = min(cornerRadius, rect.height / 2, rect.width / 2)
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
}
