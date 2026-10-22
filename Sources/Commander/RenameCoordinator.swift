import AppKit
import FileManagerCore

@MainActor
final class RenameCoordinator {
    private let mover: any FileMoving
    private let presenter = OperationDialogPresenter()
    private(set) var isBusy = false

    init(mover: any FileMoving = LocalFileMover()) { self.mover = mover }

    func begin(source: URL, window: NSWindow, onCreated: @escaping (URL) -> Void) {
        guard !isBusy, window.attachedSheet == nil else { return }
        isBusy = true
        ask(source: source, name: source.lastPathComponent, window: window, onCreated: onCreated)
    }

    private func ask(source: URL, name: String, window: NSWindow, onCreated: @escaping (URL) -> Void) {
        let dialog = TerminalOperationDialog(mode: .textInput(title: "Rename",
            prompt: "New name:", value: name, confirmTitle: "Rename"))
        dialog.onCancel = { [weak self] in self?.finish(window: window) }
        dialog.onConfirm = { [weak self] name in
            guard let self else { return }
            self.presenter.present(TerminalOperationDialog(mode: .busy(title: "Rename",
                message: "Renaming…\n\n\(name)")), window: window)
            let mover = self.mover
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try FileRenamer(mover: mover).rename(source: source, name: name) }
                }.value
                switch result {
                case .success(let url):
                    self.finish(window: window)
                    onCreated(url)
                case .failure(let error):
                    let errorDialog = TerminalOperationDialog(mode: .error(message: error.localizedDescription,
                        title: "Rename error"))
                    errorDialog.onDismiss = { [weak self] in
                        self?.ask(source: source, name: name, window: window, onCreated: onCreated)
                    }
                    self.presenter.present(errorDialog, window: window)
                }
            }
        }
        presenter.present(dialog, window: window)
    }

    private func finish(window: NSWindow) {
        presenter.dismiss(window: window)
        isBusy = false
    }
}
