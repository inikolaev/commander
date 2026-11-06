import AppKit
import EditorCore
import TextSearchCore

@MainActor
private final class EditorSearchSnapshotStore {
    var snapshot: EditorSearchSnapshot
    init(_ snapshot: EditorSearchSnapshot) { self.snapshot = snapshot }
}

/// Owns the editor lifetime and modal file operations, independently of rendering.
@MainActor
final class FileEditorCoordinator {
    var responder: NSResponder? { view }
    var onClose: (() -> Void)?
    private(set) var isBusy = false
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private var view: TerminalFileEditor?
    private var file: EditorFile?
    private var searchController: DocumentSearchController<Int, EditorSearchHit, Int>?
    private var searchSurface: DocumentSearchSurface?
    private var searchSnapshots: EditorSearchSnapshotStore?
    private var contentObserver: UUID?
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
        editor.startSyntax(initialText: file.text)
        view = editor
        editor.onSave = { [weak self] in self?.save() }
        editor.onClose = { [weak self] in self?.requestClose() }
        editor.onSearchAction = { [weak self] action in self?.handleSearch(action) }
        editor.onManualNavigation = { [weak self] origin in self?.searchController?.manualNavigation(to: origin) }
        editor.onContentChange = { [weak self] origin in self?.documentChanged(origin: origin) }
        contentObserver = editor.document.addContentChangeObserver { [weak self, weak editor] _ in
            self?.documentChanged(origin: editor?.selection.range.location ?? 0)
        }
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
    private func documentChanged(origin: Int) {
        guard let view, let searchController else { return }
        searchSnapshots?.snapshot = view.document.makeSearchSnapshot()
        searchController.documentDidChange(origin: origin)
    }

    private func handleSearch(_ action: DocumentSearchKeyAction) {
        switch action {
        case .focus: openSearch()
        case .forward, .backward:
            if searchSurface == nil { openSearch() }
            searchController?.continueSearch(action == .forward ? .forward : .backward)
        case .dismiss: searchSurface?.dismissAndRestoreFocus()
        case .none: break
        }
    }

    func openSearch() {
        guard let editor = view, !isBusy else { return }
        if let searchSurface { searchSurface.focus(contentResponder: editor); return }
        let store = EditorSearchSnapshotStore(editor.document.makeSearchSnapshot())
        let origin = editor.selection.range.location
        let controller = DocumentSearchController<Int, EditorSearchHit, Int>(
            origin: origin,
            revision: { [weak editor] in editor?.document.contentVersion ?? -1 },
            hitStart: { $0.exactRange.location },
            wrapStart: { direction in
                let length = await store.snapshot.length
                return direction == .forward ? 0 : (length > 0 ? length - 1 : nil)
            },
            scan: { query, direction, anchor, limit, _ in
                let snapshot = await store.snapshot
                let worker = Task.detached(priority: .userInitiated) {
                    snapshot.search(TextSearchQuery(text: query.text,
                        caseSensitive: query.caseSensitive, wholeWord: query.wholeWord),
                        direction: direction == .forward ? .forward : .backward,
                        fromUTF16Offset: anchor, exclusiveStartLimit: limit,
                        isCancelled: { Task.isCancelled })
                }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                switch result {
                case .found(let hit): return .found(hit)
                case .exhausted: return .exhausted
                case .cancelled: return .cancelled
                }
            },
            validate: { hit, _ in hit.isCurrent(contentVersion: await store.snapshot.contentVersion) }
        )
        let surface = DocumentSearchSurface(frame: .zero)
        surface.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: editor.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: editor.bottomAnchor,
                                            constant: -TerminalTheme.lineHeight),
            surface.heightAnchor.constraint(equalToConstant: TerminalFileEditor.searchBarHeight),
        ])
        surface.onQueryChange = { [weak self] query in self?.searchController?.setQuery(query) }
        surface.onContinue = { [weak self] direction in self?.searchController?.continueSearch(direction) }
        surface.onDismiss = { [weak self] in self?.dismissSearch() }
        controller.onStatus = { [weak surface] status in surface?.update(status: status.displayText) }
        controller.onHit = { [weak editor] hit, _ in
            guard let editor, hit.isCurrent(contentVersion: editor.document.contentVersion) else { return }
            editor.selection.clearAdditionalCarets()
            editor.selection.select(hit.selectionRange)
            editor.changed()
        }
        searchController = controller
        searchSurface = surface
        searchSnapshots = store
        editor.searchActive = true
        controller.open(at: origin)
        surface.focus(contentResponder: editor)
    }

    private func dismissSearch() {
        searchController?.close()
        searchController = nil
        searchSurface = nil
        searchSnapshots = nil
        view?.searchActive = false
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
        searchSurface?.removeFromSuperview()
        dismissSearch()
        if let contentObserver, let view { view.document.removeContentChangeObserver(contentObserver) }
        contentObserver = nil
        if let window { presenter.dismiss(window: window) }
        isBusy = false
        view?.stopSyntax()
        view?.removeFromSuperview()
        view = nil
        window?.makeFirstResponder(previousResponder)
        onClose?()
    }
}
