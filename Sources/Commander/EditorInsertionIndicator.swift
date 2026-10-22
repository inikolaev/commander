import AppKit

/// Keeps cursor animation independent of the document's drawing work.
@MainActor
final class EditorInsertionIndicator {
    enum DisplayMode { case hidden, visible, blinking }

    let view: NSView
    private var blinkTimer: Timer?
    init() {
        if #available(macOS 14, *) {
            let indicator = SystemInsertionIndicator(frame: .zero)
            indicator.displayMode = .hidden
            indicator.automaticModeOptions = []
            view = indicator
        } else {
            view = LegacyInsertionIndicator(frame: .zero)
            view.wantsLayer = true
        }
        view.isHidden = true
        view.setAccessibilityElement(false)
    }
    isolated deinit { blinkTimer?.invalidate() }

    func update(_ mode: DisplayMode, restart: Bool = false) {
        view.isHidden = mode == .hidden
        if #available(macOS 14, *), let indicator = view as? NSTextInsertionIndicator {
            indicator.color = TerminalTheme.primaryText
            // Movement and edits should immediately reveal a cursor in its off phase.
            if restart && mode != .hidden { indicator.displayMode = .visible }
            switch mode {
            case .hidden: indicator.displayMode = .hidden
            case .visible: indicator.displayMode = .visible
            case .blinking: indicator.displayMode = .automatic
            }
            return
        }

        // macOS 13 predates NSTextInsertionIndicator. Reset the next blink on
        // input so continuous typing keeps the insertion point visible.
        view.layer?.backgroundColor = TerminalTheme.primaryText.cgColor
        if mode != .blinking {
            blinkTimer?.invalidate()
            blinkTimer = nil
            view.alphaValue = 1
        } else if let blinkTimer {
            if restart {
                view.alphaValue = 1
                blinkTimer.fireDate = Date(timeIntervalSinceNow: 0.5)
            }
        } else {
            view.alphaValue = 1
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.view.alphaValue = self.view.alphaValue == 0 ? 1 : 0
                }
            }
            blinkTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

// The cursor must not intercept clicks intended for the editor.
@available(macOS 14, *)
private final class SystemInsertionIndicator: NSTextInsertionIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class LegacyInsertionIndicator: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
