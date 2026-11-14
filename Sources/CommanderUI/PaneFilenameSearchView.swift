import AppKit

/// Small search dialog attached to the bottom of the pane being searched.
@MainActor
final class PaneFilenameSearchView: TerminalDialogView, NSTextFieldDelegate {
    private let panelGray = NSColor(srgbRed: 0.72, green: 0.72, blue: 0.72, alpha: 1)
    private let inputTeal = NSColor(srgbRed: 0, green: 0.54, blue: 0.55, alpha: 1)
    private let caretRed = NSColor(srgbRed: 1, green: 0.38, blue: 0.42, alpha: 1)
    var onQueryChange: ((String) -> Bool)?
    var onContinue: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onFocusLost: (() -> Void)?
    private let field = NSTextField()
    private let caret = SearchUnderlineCaret(frame: .zero)
    private weak var styledEditor: NSTextView?
    private var previousCaretColor: NSColor?
    private var previousEditorBackground: Bool?
    private(set) var query = ""
    var isComposingText: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() == true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        field.delegate = self
        field.isBordered = false
        field.isBezeled = false
        // Paint the input in draw(_:), as TerminalOperationDialog does. AppKit's
        // shared field editor otherwise covers the field background while editing.
        field.drawsBackground = false
        field.textColor = .black
        field.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Search filenames in active pane")
        caret.wantsLayer = true
        caret.layer?.backgroundColor = caretRed.cgColor
        caret.isHidden = true
        caret.setAccessibilityElement(false)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(caret)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 23.5),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -23.5),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 22.5),
            field.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let outer = NSRect(x: 2.5, y: 8.5, width: bounds.width - 5, height: bounds.height - 18)
        drawDialogFrame(panel: bounds, outerBorder: outer, title: "Search",
                        titleFont: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
                        background: panelGray, foreground: .black)
        inputTeal.setFill()
        field.frame.fill()
    }

    func focus() {
        superview?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        styleFieldEditor()
        field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        updateCaret()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        styleFieldEditor()
        updateCaret()
    }

    private func styleFieldEditor() {
        guard let editor = field.currentEditor() as? NSTextView, styledEditor !== editor else { return }
        restoreFieldEditor()
        styledEditor = editor
        previousCaretColor = editor.insertionPointColor
        previousEditorBackground = editor.drawsBackground
        editor.drawsBackground = false
        editor.insertionPointColor = .clear
        NotificationCenter.default.addObserver(self, selector: #selector(editorSelectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification, object: editor)
    }

    func restoreFieldEditor() {
        guard let editor = styledEditor else { return }
        NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: editor)
        if let previousCaretColor { editor.insertionPointColor = previousCaretColor }
        if let previousEditorBackground { editor.drawsBackground = previousEditorBackground }
        styledEditor = nil
        previousCaretColor = nil
        previousEditorBackground = nil
        caret.isHidden = true
    }

    @objc private func editorSelectionChanged(_ notification: Notification) { updateCaret() }

    private func updateCaret() {
        guard let editor = styledEditor, let window else { caret.isHidden = true; return }
        let selection = editor.selectedRange()
        let screenRect = editor.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0),
            actualRange: nil)
        let windowRect = window.convertFromScreen(screenRect)
        let local = convert(NSPoint(x: windowRect.minX, y: windowRect.minY), from: nil)
        let x = max(field.frame.minX + 2, min(local.x, field.frame.maxX - 14))
        caret.frame = NSRect(x: x, y: field.frame.maxY - 3, width: 12, height: 3)
        caret.isHidden = false
    }

    @discardableResult
    func append(_ text: String) -> Bool {
        let length = (query as NSString).length
        let editorRange = field.currentEditor()?.selectedRange
        let selection = if let editorRange, editorRange.location <= length,
                           editorRange.length <= length - editorRange.location {
            editorRange
        } else { NSRange(location: length, length: 0) }
        let replacement = (query as NSString).replacingCharacters(in: selection, with: text)
        guard change(to: replacement) else { return false }
        field.currentEditor()?.selectedRange = NSRange(location: selection.location + (text as NSString).length, length: 0)
        updateCaret()
        return true
    }

    func change(to text: String, moveCaretToEnd: Bool = true) -> Bool {
        guard onQueryChange?(text) == true else { return false }
        query = text
        if field.stringValue != text { field.stringValue = text }
        if moveCaretToEnd { field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        updateCaret()
        return true
    }

    func clearUnmatchedQuery() {
        query = ""
        field.stringValue = ""
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
        updateCaret()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        let typed = field.stringValue
        if !change(to: typed, moveCaretToEnd: false) { field.stringValue = query }
        updateCaret()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        restoreFieldEditor()
        onFocusLost?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onDismiss?()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.control) { onContinue?(flags.contains(.shift)) }
            else { onDismiss?() }
            return true
        default: return false
        }
    }
}

@MainActor
private final class SearchUnderlineCaret: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
