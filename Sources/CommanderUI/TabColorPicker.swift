import AppKit

enum TabColor: String, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray
    var title: String { rawValue.capitalized }
    var nsColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .teal: .systemTeal
        case .gray: .systemGray
        }
    }
}

@MainActor
final class TabColorPicker: NSView {
    var onChoose: ((TabColor?) -> Void)?
    private let choices: [TabColor?] = [nil] + TabColor.allCases.map { $0 }
    private var buttons: [NSButton] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 78))
        // A static label keeps normal menu contrast without becoming an action.
        let heading = NSTextField(labelWithString: "Tab Color")
        heading.font = .menuFont(ofSize: 0)
        heading.textColor = .labelColor
        heading.isSelectable = false
        heading.frame = NSRect(x: 20, y: 54, width: 132, height: 20)
        addSubview(heading)
        for (index, color) in choices.enumerated() {
            let button = NSButton(frame: NSRect(x: 18 + (index % 5) * 24, y: 28 - (index / 5) * 24, width: 24, height: 24))
            button.tag = index
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(choose(_:))
            button.toolTip = color?.title ?? "No Color"
            button.setAccessibilityLabel(color?.title ?? "No Color")
            addSubview(button)
            buttons.append(button)
        }
        update(selected: nil, enabled: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(selected: TabColor?, enabled: Bool) {
        for (index, button) in buttons.enumerated() {
            let color = choices[index]
            let chosen = color == selected
            button.isEnabled = enabled
            button.setAccessibilityValue(chosen ? "Selected" : "Not selected")
            button.image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
                let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
                if let color { color.nsColor.setFill(); circle.fill() }
                else {
                    NSColor.secondaryLabelColor.setStroke()
                    circle.lineWidth = 1.5
                    circle.stroke()
                    let slash = NSBezierPath()
                    slash.move(to: NSPoint(x: 4, y: 18))
                    slash.line(to: NSPoint(x: 18, y: 4))
                    slash.lineWidth = 1.5
                    slash.stroke()
                }
                if chosen {
                    NSColor.labelColor.setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
                return true
            }
        }
    }
    @objc private func choose(_ sender: NSButton) { onChoose?(choices[sender.tag]) }
}
