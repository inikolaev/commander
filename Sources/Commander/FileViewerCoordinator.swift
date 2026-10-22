import AppKit
import FileManagerCore
import SyntaxCore

/// Coalesces navigation input while disk reads run on the document actor.
@MainActor
final class FileViewerCoordinator {
    var isBusy: Bool { task != nil || showingError }
    private(set) var view: TerminalFileViewer?
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private var document: FileViewerDocument?
    private var syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter.shared
    private var task: Task<Void, Never>?
    private var pendingScroll = 0
    private var pendingJump: ViewerCommand?
    private var reload = false
    private var mode: ViewerMode = .text
    private var wrapsText = true
    private var closed = false
    private var showingError = false
    private let errors = OperationDialogPresenter()
    private let loading = OperationDialogPresenter()
    private var loadingTask: Task<Void, Never>?
    private var loadingVisible = false
    var onClose: (() -> Void)?

    func present(url: URL, window: NSWindow) {
        present(url: url, displayPath: url.path, window: window) {
            try LocalFileContentSource(url: url)
        }
    }

    func present(url: URL, displayPath: String, window: NSWindow,
                 openSource: @escaping @Sendable () async throws -> any FileContentSource) {
        guard let content = window.contentView else { return }
        self.window = window
        previousResponder = window.firstResponder
        beginLoading()
        task = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    let source = try await openSource()
                    try Task.checkCancellation()
                    let document = FileViewerDocument(source: source)
                    var highlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter.shared
                    let registry = SyntaxRegistry.viewer
                    if registry.supports(url), let size = try await source.metadata().size,
                       size <= Int64(SyntaxRegistry.defaultMaximumFileSize) {
                        let data = try await source.read(at: 0, count: Int(size))
                        highlighter = registry.highlighter(for: url, data: data)
                    }
                    return (document, highlighter)
                }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !self.closed, !Task.isCancelled else { return }
                let (document, syntaxHighlighter) = prepared
                // Prepare the first page offscreen: failed opens/reads leave the panes visible.
                let viewer = TerminalFileViewer(path: displayPath, syntaxHighlighter: syntaxHighlighter)
                viewer.frame = content.bounds
                viewer.wrapsText = self.wrapsText
                let page = try await document.page(
                    rows: viewer.visibleRows,
                    wrapColumns: self.wrapsText ? viewer.visibleColumns : nil,
                    includeSourceText: syntaxHighlighter.isActive
                )
                guard !self.closed, !Task.isCancelled else { return }
                let syntaxProjection = await Task.detached(priority: .userInitiated) {
                    ViewerSyntaxProjection.make(page: page, highlighter: syntaxHighlighter)
                }.value
                guard !self.closed, !Task.isCancelled else { return }
                self.document = document
                self.syntaxHighlighter = syntaxHighlighter
                viewer.update(page, syntaxProjection: syntaxProjection)
                self.finishLoading()
                self.install(viewer, in: content, window: window)
                self.task = nil
                self.request(.stay)
            } catch {
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.task = nil
                self.finishLoading()
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
        viewer.onResize = { [weak self, weak viewer] in
            guard viewer?.window != nil else { return }
            self?.request(.stay)
        }
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
        beginLoading()
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.finishLoading() }
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
                    let highlighter = self.syntaxHighlighter
                    let page = try await document.page(
                        command,
                        rows: self.view?.visibleRows ?? 1,
                        mode: requestedMode,
                        wrapColumns: wrapColumns,
                        includeSourceText: highlighter.isActive
                    )
                    let syntaxProjection = await Task.detached(priority: .userInitiated) {
                        ViewerSyntaxProjection.make(page: page, highlighter: highlighter)
                    }.value
                    guard !self.closed, !Task.isCancelled else { return }
                    if requestedMode == self.mode && requestedWrap == self.wrapsText {
                        self.view?.update(page, syntaxProjection: syntaxProjection)
                    }
                }
            } catch is CancellationError {
                // Closing the viewer cancels pending page work.
            } catch {
                if !self.closed { self.showError(error) }
            }
        }
    }

    private func beginLoading() {
        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !self.closed, self.task != nil, let window = self.window else { return }
            let dialog = TerminalOperationDialog(mode: .choice(title: "Reading file",
                message: "Preparing file contents…", buttons: ["Cancel"]))
            dialog.onCancel = { [weak self] in self?.close() }
            dialog.onChoice = { [weak self] _ in self?.close() }
            self.loadingVisible = true
            self.loading.present(dialog, window: window)
        }
    }

    private func finishLoading() {
        loadingTask?.cancel(); loadingTask = nil
        if loadingVisible, let window { loading.dismiss(window: window) }
        loadingVisible = false
    }

    private func showError(_ error: Error) {
        finishLoading()
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
        finishLoading()
        if showingError, let window { errors.dismiss(window: window) }
        task?.cancel()
        task = nil
        document = nil
        syntaxHighlighter = PlainTextSyntaxHighlighter.shared
        view?.removeFromSuperview()
        view = nil
        window?.makeFirstResponder(previousResponder)
        onClose?()
    }
}
