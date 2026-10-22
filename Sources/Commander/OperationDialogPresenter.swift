import AppKit

/// Shared presentation and focus restoration for modal file operations.
@MainActor
final class OperationDialogPresenter {
    private var overlay: TerminalOperationDialog?
    private weak var previousResponder: NSResponder?

    func present(_ dialog: TerminalOperationDialog, window: NSWindow) {
        if overlay == nil { previousResponder = window.firstResponder }
        overlay?.removeFromSuperview()
        overlay = dialog
        guard let content = window.contentView else { dismiss(window: window); return }
        dialog.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dialog)
        NSLayoutConstraint.activate([
            dialog.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dialog.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dialog.topAnchor.constraint(equalTo: content.topAnchor),
            dialog.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        dialog.focusInitialControl()
    }

    func dismiss(window: NSWindow) {
        overlay?.removeFromSuperview()
        overlay = nil
        window.makeFirstResponder(previousResponder)
        previousResponder = nil
    }
}
