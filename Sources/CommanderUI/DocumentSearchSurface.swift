import AppKit

enum DocumentSearchKeyAction: Equatable {
    case focus
    case forward
    case backward
    case dismiss
    case none

    static func action(for event: NSEvent, searchActive: Bool) -> Self {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f" where !flags.contains(.shift): return .focus
            case "g": return flags.contains(.shift) ? .backward : .forward
            default: break
            }
        }
        // Check modified function keys before any generic F7 handling.
        if event.keyCode == 98 && !flags.contains(.command) && !flags.contains(.control) {
            if flags == .shift { return .forward }
            if flags == .option { return .backward }
            if flags.isEmpty { return .focus }
        }
        if searchActive && event.keyCode == 53 && flags.isEmpty { return .dismiss }
        return .none
    }
}

/// Compact in-window search bar. It owns focus and controls, while the search
/// controller owns the query, task, and result state.
@MainActor
final class DocumentSearchSurface: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 34
    var onQueryChange: ((DocumentSearchQuery) -> Void)?
    var onContinue: ((DocumentSearchDirection) -> Void)?
    var onDismiss: (() -> Void)?
    private let field = SearchTextField()
    private let caseButton = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let wordButton = NSButton(checkboxWithTitle: "Word", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private weak var contentResponder: NSResponder?
    private var query = DocumentSearchQuery()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "Search this file"
        field.setAccessibilityLabel("Search this file")
        field.font = TerminalTheme.font
        field.delegate = self
        field.actionForKey = { [weak self] action in self?.handle(action) }
        caseButton.setAccessibilityLabel("Case sensitive")
        wordButton.setAccessibilityLabel("Whole word")
        for button in [caseButton, wordButton] {
            button.font = TerminalTheme.font
            button.target = self
            button.action = #selector(optionsChanged(_:))
        }
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.setAccessibilityLabel("Close search")
        statusLabel.font = TerminalTheme.font
        statusLabel.textColor = TerminalTheme.contrastText
        statusLabel.lineBreakMode = .byTruncatingTail
        for view in [field, caseButton, wordButton, statusLabel, closeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            caseButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            caseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            wordButton.leadingAnchor.constraint(equalTo: caseButton.trailingAnchor, constant: 4),
            wordButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: wordButton.trailingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            closeButton.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        TerminalTheme.selection.setFill()
        bounds.fill()
    }

    /// The host controls placement; this helper remembers where Escape returns.
    func focus(contentResponder: NSResponder) {
        self.contentResponder = contentResponder
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func dismissAndRestoreFocus() {
        let hostWindow = window
        removeFromSuperview()
        if let contentResponder { hostWindow?.makeFirstResponder(contentResponder) }
        onDismiss?()
    }

    func update(query: DocumentSearchQuery) {
        self.query = query
        if !field.stringValue.unicodeScalars.elementsEqual(query.text.unicodeScalars) {
            field.stringValue = query.text
        }
        caseButton.state = query.caseSensitive ? .on : .off
        wordButton.state = query.wholeWord ? .on : .off
    }

    func update(status: String) { statusLabel.stringValue = status }

    func controlTextDidChange(_ obj: Notification) {
        // Marked text remains in AppKit until the IME commits it.
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        query.text = field.stringValue
        onQueryChange?(query)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if textView.hasMarkedText() { return false }
            onContinue?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .backward : .forward)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if textView.hasMarkedText() { return false }
            onContinue?(.backward)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if textView.hasMarkedText() { return false }
            dismissAndRestoreFocus()
            return true
        default: return false
        }
    }

    @objc private func optionsChanged(_ sender: Any?) {
        query.caseSensitive = caseButton.state == .on
        query.wholeWord = wordButton.state == .on
        onQueryChange?(query)
    }

    @objc private func closeClicked(_ sender: Any?) { dismissAndRestoreFocus() }

    private func handle(_ action: DocumentSearchKeyAction) {
        switch action {
        case .focus: window?.makeFirstResponder(field)
        case .forward: onContinue?(.forward)
        case .backward: onContinue?(.backward)
        case .dismiss: dismissAndRestoreFocus()
        case .none: break
        }
    }
}

@MainActor
private final class SearchTextField: NSTextField {
    var actionForKey: ((DocumentSearchKeyAction) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 && (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            return super.performKeyEquivalent(with: event)
        }
        let action = DocumentSearchKeyAction.action(for: event, searchActive: true)
        guard action != .none else { return super.performKeyEquivalent(with: event) }
        actionForKey?(action)
        return true
    }
}
