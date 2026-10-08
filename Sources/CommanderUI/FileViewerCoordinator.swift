import AppKit
import FileManagerCore
import SyntaxCore

/// Coalesces navigation input while disk reads run on the document actor.
@MainActor
final class FileViewerCoordinator {
    private(set) var view: TerminalFileViewer?
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private var document: FileViewerDocument?
    private var task: Task<Void, Never>?
    private var pendingScroll = 0
    private var pendingJump: ViewerCommand?
    private var reload = false
    private var mode: ViewerMode = .text
    private var wrapsText = true
    private var closed = false
    private var showingError = false
    private let errors = OperationDialogPresenter()
    var onClose: (() -> Void)?

    func present(url: URL, window: NSWindow) {
        guard let content = window.contentView else { return }
        self.window = window
        previousResponder = window.firstResponder
        task = Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let document = try FileViewerDocument(url: url)
                    let syntaxHighlighter = SyntaxRegistry.viewer.highlighter(for: url)
                    return (document, syntaxHighlighter)
                }.value
                guard let self, !self.closed, !Task.isCancelled else { return }
                let (document, syntaxHighlighter) = prepared
                // Prepare the first page offscreen: failed opens/reads leave the panes visible.
                let viewer = TerminalFileViewer(path: url.path, syntaxHighlighter: syntaxHighlighter)
                viewer.frame = content.bounds
                viewer.wrapsText = self.wrapsText
                let page = try await document.page(
                    rows: viewer.visibleRows,
                    wrapColumns: self.wrapsText ? viewer.visibleColumns : nil,
                    includeSourceText: syntaxHighlighter.isActive
                )
                guard !self.closed, !Task.isCancelled else { return }
                self.document = document
                viewer.update(page)
                self.install(viewer, in: content, window: window)
                self.task = nil
                self.request(.stay)
            } catch {
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.task = nil
                self.showError(error)
            }
        }
    }

    private func install(_ viewer: TerminalFileViewer, in content: NSView, window: NSWindow) {
        view = viewer
        viewer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(viewer)
        NSLayoutConstraint.activate([
            viewer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            viewer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            viewer.topAnchor.constraint(equalTo: content.topAnchor),
            viewer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        viewer.onInput = { [weak self] input in
            switch input {
            case .close: self?.close()
            case .toggleMode: self?.toggleMode()
            case .toggleWrap: self?.toggleWrap()
            case .navigate(let command): self?.request(command)
            }
        }
        viewer.onResize = { [weak self] in self?.request(.stay) }
        window.makeFirstResponder(viewer)
    }

    func toggleMode() {
        guard !closed, !showingError else { return }
        mode = mode == .text ? .hex : .text
        pendingScroll = 0
        pendingJump = nil
        request(.stay)
    }

    func toggleWrap() {
        guard !closed, !showingError, mode == .text else { return }
        wrapsText.toggle()
        view?.wrapsText = wrapsText
        pendingScroll = 0
        pendingJump = nil
        request(.stay)
    }

    func request(_ command: ViewerCommand) {
        guard !closed, !showingError else { return }
        switch command {
        case .scroll(let delta): pendingScroll = max(-200, min(200, pendingScroll + max(-200, min(200, delta))))
        case .home, .end: pendingJump = command; pendingScroll = 0
        case .stay: reload = true
        }
        guard task == nil, let document else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                while !self.closed && (self.reload || self.pendingJump != nil || self.pendingScroll != 0) {
                    let command: ViewerCommand
                    if let jump = self.pendingJump { command = jump; self.pendingJump = nil }
                    else if self.pendingScroll != 0 { command = .scroll(self.pendingScroll); self.pendingScroll = 0 }
                    else { command = .stay }
                    self.reload = false
                    let requestedMode = self.mode
                    let requestedWrap = self.wrapsText
                    let wrapColumns = requestedMode == .text && requestedWrap ? self.view?.visibleColumns : nil
                    let page = try await document.page(
                        command,
                        rows: self.view?.visibleRows ?? 1,
                        mode: requestedMode,
                        wrapColumns: wrapColumns,
                        includeSourceText: self.view?.syntaxHighlightingEnabled == true
                    )
                    guard !self.closed, !Task.isCancelled else { return }
                    if requestedMode == self.mode && requestedWrap == self.wrapsText { self.view?.update(page) }
                }
            } catch is CancellationError {
                // Closing the viewer cancels pending page work.
            } catch {
                if !self.closed { self.showError(error) }
            }
        }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        showingError = true
        let dialog = TerminalOperationDialog(mode: .error(message: error.localizedDescription, title: "Viewer error"))
        dialog.onDismiss = { [weak self] in
            self?.errors.dismiss(window: window)
            self?.close()
        }
        errors.present(dialog, window: window)
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        task = nil
        document = nil
        view?.removeFromSuperview()
        view = nil
        window?.makeFirstResponder(previousResponder)
        onClose?()
    }
}
