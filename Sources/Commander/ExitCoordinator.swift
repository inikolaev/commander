import AppKit

/// One asynchronous exit prompt shared by every application termination route.
@MainActor
final class ExitCoordinator {
    private let presenter = OperationDialogPresenter()
    private(set) var isPresented = false

    func request(window: NSWindow, operationInProgress: Bool, requiresConfirmation: Bool = true,
                 completion: @escaping (Bool) -> Void) {
        guard !isPresented else { return }
        if !requiresConfirmation && !operationInProgress {
            // Let applicationShouldTerminate return .terminateLater before the
            // caller prepares documents and replies to AppKit's quit request.
            DispatchQueue.main.async { completion(true) }
            return
        }
        isPresented = true
        let dialog: TerminalOperationDialog
        if operationInProgress {
            dialog = TerminalOperationDialog(mode: .error(
                message: "Finish or cancel the current file operation before quitting.", title: "Exit"))
            dialog.onDismiss = { [weak self] in self?.finish(window: window, confirmed: false, completion: completion) }
        } else {
            dialog = TerminalOperationDialog(mode: .decision(title: "Exit",
                message: "Do you want to quit Commander?", confirmTitle: "Quit", destructive: false))
            dialog.onConfirm = { [weak self] _ in self?.finish(window: window, confirmed: true, completion: completion) }
            dialog.onCancel = { [weak self] in self?.finish(window: window, confirmed: false, completion: completion) }
        }
        window.makeKeyAndOrderFront(nil)
        presenter.present(dialog, window: window)
    }

    private func finish(window: NSWindow, confirmed: Bool, completion: (Bool) -> Void) {
        guard isPresented else { return }
        presenter.dismiss(window: window)
        isPresented = false
        completion(confirmed)
    }
}
