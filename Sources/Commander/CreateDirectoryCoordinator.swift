import AppKit
import FileManagerCore

@MainActor
final class CreateDirectoryCoordinator {
    private let creator: any DirectoryCreating
    private let presenter = OperationDialogPresenter()
    private(set) var isBusy = false

    init(creator: any DirectoryCreating = LocalDirectoryCreator()) { self.creator = creator }

    func begin(directory: URL, window: NSWindow, onCreated: @escaping (URL) -> Void) {
        guard !isBusy, window.attachedSheet == nil else { return }
        isBusy = true
        ask(directory: directory, name: "", window: window, onCreated: onCreated)
    }

    private func ask(directory: URL, name: String, window: NSWindow, onCreated: @escaping (URL) -> Void) {
        let dialog = TerminalOperationDialog(mode: .textInput(title: "Create directory",
            prompt: "Directory name:", value: name, confirmTitle: "Create"))
        dialog.onCancel = { [weak self] in self?.finish(window: window) }
        dialog.onConfirm = { [weak self] name in
            guard let self else { return }
            self.presenter.present(TerminalOperationDialog(mode: .busy(title: "Create directory",
                message: "Creating directory…\n\n\(name)")), window: window)
            let creator = self.creator
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try creator.create(name: name, in: directory) }
                }.value
                switch result {
                case .success(let url):
                    self.finish(window: window)
                    onCreated(url)
                case .failure(let error):
                    let errorDialog = TerminalOperationDialog(mode: .error(message: error.localizedDescription,
                        title: "Create directory error"))
                    errorDialog.onDismiss = { [weak self] in
                        self?.ask(directory: directory, name: name, window: window, onCreated: onCreated)
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
