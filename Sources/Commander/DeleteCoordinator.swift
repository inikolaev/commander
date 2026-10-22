import AppKit
import FileManagerCore

/// Confirms a snapshot of the selected item, then performs the move off the UI thread.
@MainActor
final class DeleteCoordinator {
    private let trasher: any FileTrashing
    private let presenter = OperationDialogPresenter()
    private(set) var isBusy = false

    init(trasher: any FileTrashing = LocalFileTrasher()) { self.trasher = trasher }

    func begin(item: URL, isDirectory: Bool, window: NSWindow,
               onStart: @escaping () -> Void, onFinish: @escaping (Result<Void, Error>) -> Void) {
        begin(items: [item], includesDirectories: isDirectory, window: window, onStart: onStart,
              onFinish: { onFinish($0.map { _ in () }) })
    }

    func begin(items: [URL], includesDirectories: Bool, window: NSWindow,
               onStart: @escaping () -> Void, onFinish: @escaping (Result<[URL], Error>) -> Void) {
        guard !items.isEmpty, !isBusy, window.attachedSheet == nil else { return }
        isBusy = true
        let kind = includesDirectories ? "folder and its contents" : "file"
        let question = items.count == 1 ? "Move this \(kind) to Trash?" :
            "Move \(items.count) selected items to Trash?" + (includesDirectories ? " Folders include their contents." : "")
        let names = items.prefix(3).map(\.lastPathComponent).joined(separator: ", ") + (items.count > 3 ? ", …" : "")
        let dialog = TerminalOperationDialog(mode: .decision(title: "Delete",
            message: "\(question)\n\n\(names)\n\nYou can recover them from macOS Trash.", confirmTitle: "Trash"))
        dialog.toolTip = items.map(\.path).joined(separator: "\n")
        dialog.onCancel = { [weak self] in self?.finish(window: window) }
        dialog.onConfirm = { [weak self] _ in
            guard let self else { return }
            let busy = TerminalOperationDialog(mode: .busy(title: "Delete", message: "Moving \(items.count) item(s) to Trash…\n\n\(names)"))
            self.presenter.present(busy, window: window)
            onStart()
            let trasher = self.trasher
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try FileTrashBatch.run(items: items, using: trasher) }
                }.value
                switch result {
                case .success:
                    self.finish(window: window)
                    onFinish(result)
                case .failure(let error):
                    let errorDialog = TerminalOperationDialog(mode: .error(message: error.localizedDescription, title: "Delete error"))
                    errorDialog.toolTip = error.localizedDescription
                    errorDialog.onDismiss = { [weak self] in self?.finish(window: window); onFinish(result) }
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
