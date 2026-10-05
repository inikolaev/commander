import AppKit

/// Compact title-bar control shown when Sparkle finds an update in the background.
@MainActor
final class UpdateAvailableButton: NSView {
    private enum Metrics {
        static let height: CGFloat = 26
        static let horizontalPadding: CGFloat = 12
        static let imageTitleSpacing: CGFloat = 6
        static let trailingTitlebarSpacing: CGFloat = 10
    }

    private static let background = NSColor(
        srgbRed: 1.0,
        green: 0.67,
        blue: 0.22,
        alpha: 1
    )

    init(target: AnyObject?, action: Selector?) {
        let button = NSButton(title: "Update Available", target: target, action: action)
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        button.contentTintColor = .black
        button.image = NSImage(
            systemSymbolName: "shippingbox.fill",
            accessibilityDescription: "Update available"
        )
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.wantsLayer = true
        button.layer?.backgroundColor = Self.background.cgColor
        button.layer?.cornerRadius = Metrics.height / 2

        button.sizeToFit()
        let buttonWidth = button.frame.width + Metrics.horizontalPadding * 2
        button.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: Metrics.height)

        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: buttonWidth + Metrics.trailingTitlebarSpacing,
            height: Metrics.height
        ))

        addSubview(button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
