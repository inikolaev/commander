import AppKit
import EditorCore

/// Owns the editor lifetime and modal file operations, independently of rendering.
@MainActor
final class FileEditorCoordinator {
    var onClose: (() -> Void)?
    private(set) var isBusy = false
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private var view: TerminalFileEditor?
    private var file: EditorFile?
    private let presenter = OperationDialogPresenter()

    func presentNewFile(directory: URL, window: NSWindow) {
        self.window = window
        previousResponder = window.firstResponder
        isBusy = true
        askFileName(directory: directory, name: "", window: window)
    }

    private func askFileName(directory: URL, name: String, window: NSWindow) {
        let dialog = TerminalOperationDialog(mode: .textInput(title: "New file",
            prompt: "File name:", value: name, confirmTitle: "Edit"))
        dialog.onCancel = { [weak self] in self?.finish() }
        dialog.onConfirm = { [weak self] name in
            guard let self else { return }
            self.presenter.present(TerminalOperationDialog(mode: .busy(title: "Editor",
                message: "Opening \(name)…")), window: window)
            Task { [weak self] in
                do {
                    let file = try await Task.detached { try EditorFile.openOrNew(name: name, in: directory) }.value
                    guard let self else { return }
                    self.presenter.dismiss(window: window)
                    self.file = file
                    self.install(file, window: window)
                    self.isBusy = false
                } catch {
                    self?.showError(error) { [weak self] in
                        self?.isBusy = true
                        self?.askFileName(directory: directory, name: name, window: window)
                    }
                }
            }
        }
        presenter.present(dialog, window: window)
    }

    func present(url: URL, window: NSWindow) {
        self.window = window
        previousResponder = window.firstResponder
        isBusy = true
        presenter.present(TerminalOperationDialog(mode: .busy(title: "Editor", message: "Opening \(url.lastPathComponent)…")), window: window)
        Task { [weak self] in
            do {
                let file = try await Task.detached { try EditorFile.open(url) }.value
                guard let self else { return }
                self.presenter.dismiss(window: window)
                self.file = file
                self.install(file, window: window)
                self.isBusy = false
            } catch {
                self?.showError(error) { [weak self] in self?.finish() }
            }
        }
    }
    private func install(_ file: EditorFile, window: NSWindow) {
        guard let content = window.contentView else { finish(); return }
        let editor = TerminalFileEditor(document: EditorDocuments.make(file: file), path: file.url.path)
        view = editor
        editor.onSave = { [weak self] in self?.save() }
        editor.onClose = { [weak self] in self?.requestClose() }
        editor.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.topAnchor.constraint(equalTo: content.topAnchor),
            editor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        window.makeFirstResponder(editor)
    }
    func save(completion: ((Bool) -> Void)? = nil) {
        guard !isBusy, let file, let view, let window else { completion?(false); return }
        view.unmarkText()
        guard view.document.isModified || file.isNew else { completion?(true); return }
        isBusy = true
        let text = view.document.text(in: NSRange(location: 0, length: view.document.length))
        presenter.present(TerminalOperationDialog(mode: .busy(title: "Save", message: "Saving \(file.url.lastPathComponent)…")), window: window)
        Task { [weak self] in
            do {
                let saved = try await Task.detached { try file.save(text: text) }.value
                guard let self else { return }
                self.file = saved
                view.document.markSaved()
                self.presenter.dismiss(window: window)
                self.isBusy = false
                view.changed()
                completion?(true)
            } catch {
                self?.showError(error) { completion?(false) }
            }
        }
    }
    func requestClose(completion: ((Bool) -> Void)? = nil) {
        guard !isBusy, let window else { completion?(false); return }
        view?.unmarkText()
        guard view?.document.isModified == true else { finish(); completion?(true); return }
        isBusy = true
        let dialog = TerminalOperationDialog(mode: .choice(title: "Unsaved changes",
            message: "Save changes to \(file?.url.lastPathComponent ?? "this file")?",
            buttons: ["Save", "Discard", "Cancel"]))
        let cancel = { [weak self] in
            self?.presenter.dismiss(window: window)
            self?.isBusy = false
            completion?(false)
        }
        dialog.onCancel = cancel
        dialog.onChoice = { [weak self] index in
            guard let self else { return }
            self.presenter.dismiss(window: window)
            self.isBusy = false
            switch index {
            case 0: self.save { [weak self] saved in
                if saved { self?.finish() }
                completion?(saved)
            }
            case 1: self.finish(); completion?(true)
            default: completion?(false)
            }
        }
        presenter.present(dialog, window: window)
    }
    private func showError(_ error: Error, after: (() -> Void)? = nil) {
        guard let window else { finish(); return }
        isBusy = true
        let dialog = TerminalOperationDialog(mode: .error(message: error.localizedDescription, title: "Editor error"))
        dialog.onDismiss = { [weak self] in
            self?.presenter.dismiss(window: window)
            self?.isBusy = false
            after?()
        }
        presenter.present(dialog, window: window)
    }
    private func finish() {
        if let window { presenter.dismiss(window: window) }
        isBusy = false
        view?.removeFromSuperview()
        view = nil
        window?.makeFirstResponder(previousResponder)
        onClose?()
    }
}
