import AppKit
import FileManagerCore
import SyntaxCore
import TextSearchCore

/// Coalesces navigation input while disk reads run on the document actor.
@MainActor
final class FileViewerCoordinator {
    private struct PageIdentity: Equatable, Sendable {
        let revision: UInt64?
        let size: Int64?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.revision == rhs.revision &&
                (lhs.size == nil || rhs.size == nil || lhs.size == rhs.size)
        }
    }
    var isBusy: Bool { task != nil || showingError }
    private(set) var view: TerminalFileViewer?
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private var document: FileViewerDocument?
    private var contentSource: (any FileContentSource)?
    private var searchController: DocumentSearchController<Int64, ViewerSearchHit, PageIdentity>?
    private var searchSurface: DocumentSearchSurface?
    private var activeSearchRange: Range<Int64>?
    private var activeSearchHit: ViewerSearchHit?
    private var searchGeneration: UInt64 = 0
    private var syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter.shared
    private var task: Task<Void, Never>?
    private var wordContinuationTask: Task<ViewerWordContinuation, Error>?
    private var pendingScroll = 0
    private var pendingJump: ViewerCommand?
    private var pendingJumpIsSearchReveal = false
    private var reload = false
    private var mode: ViewerMode = .text
    private var wrapsText = true
    private var wrapStyle: ViewerWrapStyle = .character
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
                    return (source, document, highlighter)
                }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !self.closed, !Task.isCancelled else { return }
                let (source, document, syntaxHighlighter) = prepared
                // Prepare the first page offscreen: failed opens/reads leave the panes visible.
                let viewer = TerminalFileViewer(path: displayPath, syntaxHighlighter: syntaxHighlighter)
                viewer.frame = content.bounds
                viewer.wrapsText = self.wrapsText
                viewer.wrapStyle = self.wrapStyle
                let page = try await document.page(
                    rows: viewer.visibleRows,
                    wrapColumns: self.wrapsText ? viewer.visibleColumns : nil,
                    wrapStyle: self.wrapStyle,
                    includeSourceText: syntaxHighlighter.isActive
                )
                guard !self.closed, !Task.isCancelled else { return }
                let syntaxProjection = await Task.detached(priority: .userInitiated) {
                    ViewerSyntaxProjection.make(page: page, highlighter: syntaxHighlighter)
                }.value
                guard !self.closed, !Task.isCancelled else { return }
                self.document = document
                self.contentSource = source
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
            case .toggleWrapType: self?.toggleWrapType()
            case .navigate(let command): self?.request(command)
            case .search(let action): self?.handleSearch(action)
            }
        }
        viewer.onResize = { [weak self, weak viewer] in
            guard viewer?.window != nil else { return }
            self?.request(.stay)
        }
        viewer.onSelectionChanged = { [weak self] in
            self?.wordContinuationTask?.cancel()
            self?.wordContinuationTask = nil
        }
        viewer.onWordContinuationNeeded = { [weak self, weak viewer] request in
            guard let self, let viewer, let source = self.contentSource, !self.closed else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try await ViewerWordContinuation.load(from: source, request: request)
            }
            self.wordContinuationTask = worker
            Task { [weak self, weak viewer] in
                do {
                    let continuation = try await worker.value
                    guard let self, !self.closed, self.view === viewer else { return }
                    viewer?.completeWordContinuation(continuation, token: request.token)
                } catch is CancellationError {
                    // A later selection superseded this read.
                } catch {
                    guard let self, !self.closed, self.view === viewer else { return }
                    guard viewer?.failWordContinuation(token: request.token) == true else { return }
                    if case FileViewerError.sourceChanged = error { self.request(.stay) }
                    else { self.showError(error) }
                }
            }
        }
        window.makeFirstResponder(viewer)
    }

    func toggleMode() {
        guard !closed, !showingError else { return }
        mode = mode == .text ? .hex : .text
        pendingScroll = 0
        pendingJump = nil
        pendingJumpIsSearchReveal = false
        request(activeSearchHit.map { .reveal(byteOffset: $0.lowerBound) } ?? .stay)
    }

    func toggleWrap() {
        guard !closed, !showingError, mode == .text else { return }
        wrapsText.toggle()
        view?.wrapsText = wrapsText
        pendingScroll = 0
        pendingJump = nil
        pendingJumpIsSearchReveal = false
        request(activeSearchHit.map { .reveal(byteOffset: $0.lowerBound) } ?? .stay)
    }

    func toggleWrapType() {
        guard !closed, !showingError, mode == .text else { return }
        wrapStyle = wrapStyle == .character ? .word : .character
        wrapsText = true
        view?.wrapStyle = wrapStyle
        view?.wrapsText = true
        pendingScroll = 0
        pendingJump = nil
        pendingJumpIsSearchReveal = false
        request(activeSearchHit.map { .reveal(byteOffset: $0.lowerBound) } ?? .stay)
    }

    func request(_ command: ViewerCommand) {
        guard !closed, !showingError else { return }
        if case .stay = command {} else if case .reveal = command {} else {
            searchGeneration &+= 1
            discardPendingSearchReveal()
            searchController?.manualNavigation(to: view?.page?.offset ?? 0)
            activeSearchRange = nil
            activeSearchHit = nil
            view?.activeSearchRange = nil
        }
        switch command {
        case .scroll(let delta): pendingScroll = max(-200, min(200, pendingScroll + max(-200, min(200, delta))))
        case .home, .end, .reveal:
            pendingJump = command
            pendingJumpIsSearchReveal = activeSearchHit != nil
            pendingScroll = 0
        case .stay: reload = true
        }
        guard task == nil, let document else { return }
        beginLoading()
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.finishLoading()
                if !self.closed && (self.reload || self.pendingJump != nil || self.pendingScroll != 0) {
                    self.request(.stay)
                }
            }
            do {
                while !self.closed && (self.reload || self.pendingJump != nil || self.pendingScroll != 0) {
                    let command: ViewerCommand
                    if let jump = self.pendingJump {
                        command = jump
                        self.pendingJump = nil
                        self.pendingJumpIsSearchReveal = false
                    }
                    else if self.pendingScroll != 0 { command = .scroll(self.pendingScroll); self.pendingScroll = 0 }
                    else { command = .stay }
                    self.reload = false
                    let requestedMode = self.mode
                    let requestedWrap = self.wrapsText
                    let requestedWrapStyle = self.wrapStyle
                    let requestedSearchGeneration = self.searchGeneration
                    let previousOffset = self.view?.page?.offset ?? 0
                    let wrapColumns = requestedMode == .text && requestedWrap ? self.view?.visibleColumns : nil
                    let highlighter = self.syntaxHighlighter
                    if let hit = self.activeSearchHit, let source = self.contentSource {
                        let adapter = ViewerSearchSource(source: source)
                        let query = self.searchController?.query ?? DocumentSearchQuery()
                        let valid = try await adapter.validate(hit, query: TextSearchQuery(
                            text: query.text, caseSensitive: query.caseSensitive,
                            wholeWord: query.wholeWord))
                        guard !self.closed, !Task.isCancelled else { return }
                        if !valid { self.invalidateSearchHit(origin: self.view?.page?.offset ?? 0) }
                    }
                    let page = try await document.page(
                        command,
                        rows: self.view?.visibleRows ?? 1,
                        mode: requestedMode,
                        wrapColumns: wrapColumns,
                        wrapStyle: requestedWrapStyle,
                        includeSourceText: highlighter.isActive,
                        activeRange: self.activeSearchRange
                    )
                    if case .reveal = command, requestedSearchGeneration != self.searchGeneration {
                        if self.pendingJump == nil {
                            self.pendingJump = .reveal(byteOffset: previousOffset)
                            self.pendingJumpIsSearchReveal = false
                        }
                        continue
                    }
                    let syntaxProjection = await Task.detached(priority: .userInitiated) {
                        ViewerSyntaxProjection.make(page: page, highlighter: highlighter)
                    }.value
                    guard !self.closed, !Task.isCancelled else { return }
                    if case .reveal = command, requestedSearchGeneration != self.searchGeneration {
                        if self.pendingJump == nil {
                            self.pendingJump = .reveal(byteOffset: previousOffset)
                            self.pendingJumpIsSearchReveal = false
                        }
                        continue
                    }
                    if requestedMode == self.mode && requestedWrap == self.wrapsText &&
                        requestedWrapStyle == self.wrapStyle {
                        let oldIdentity = self.view?.page.map {
                            PageIdentity(revision: $0.revision, size: $0.fileSize)
                        }
                        let newIdentity = PageIdentity(revision: page.revision, size: page.fileSize)
                        let pageChanged = oldIdentity.map { $0 != newIdentity } ?? false
                        let freshHitMatchesPage = self.activeSearchHit.map { hit in
                            hit.revision == page.revision &&
                            (hit.sourceSize == nil || page.fileSize == nil || hit.sourceSize == page.fileSize)
                        } ?? false
                        let restartSearch = pageChanged && !freshHitMatchesPage &&
                            self.activeSearchHit == nil && self.searchController?.isOpen == true &&
                            self.searchController?.query.text.isEmpty == false
                        if pageChanged && !freshHitMatchesPage && !restartSearch {
                            self.invalidateSearchHit(origin: page.offset)
                        }
                        self.view?.update(page, syntaxProjection: syntaxProjection)
                        if pageChanged && freshHitMatchesPage {
                            self.searchController?.displayedRevisionDidCatchUp()
                        } else if restartSearch {
                            self.searchGeneration &+= 1
                            self.searchController?.open(at: page.offset)
                        }
                        if case .scroll = command { self.searchController?.manualNavigation(to: page.offset) }
                        if case .home = command { self.searchController?.manualNavigation(to: page.offset) }
                        if case .end = command { self.searchController?.manualNavigation(to: page.offset) }
                        if case .reveal = command { self.view?.revealSearchColumn() }
                    }
                }
            } catch is CancellationError {
                // Closing the viewer cancels pending page work.
            } catch {
                if case FileViewerError.lineTooLong = error, self.mode == .text, !self.wrapsText {
                    self.wrapsText = true
                    self.view?.wrapsText = true
                    self.pendingJump = commandForActiveHit()
                    self.pendingJumpIsSearchReveal = activeSearchHit != nil
                    self.reload = true
                } else if case FileViewerError.sourceChanged = error {
                    self.invalidateSearchHit(origin: self.view?.page?.offset ?? 0)
                    self.reload = true
                } else if !self.closed { self.showError(error) }
            }
        }
    }

    private func commandForActiveHit() -> ViewerCommand {
        activeSearchRange.map { .reveal(byteOffset: $0.lowerBound) } ?? .stay
    }

    private func discardPendingSearchReveal() {
        if pendingJumpIsSearchReveal {
            pendingJump = nil
            pendingJumpIsSearchReveal = false
        }
    }

    private func invalidateSearchHit(origin: Int64) {
        searchGeneration &+= 1
        discardPendingSearchReveal()
        activeSearchHit = nil
        activeSearchRange = nil
        view?.activeSearchRange = nil
        searchController?.documentDidChange(origin: origin)
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
        guard let viewer = view, let source = contentSource, !closed else { return }
        if let searchSurface {
            searchSurface.focus(contentResponder: viewer)
            return
        }
        let adapter = ViewerSearchSource(source: source)
        let origin = viewer.page?.offset ?? 0
        let controller = DocumentSearchController<Int64, ViewerSearchHit, PageIdentity>(
            origin: origin,
            revision: { [weak viewer] in
                PageIdentity(revision: viewer?.page?.revision, size: viewer?.page?.fileSize)
            },
            hitStart: { $0.lowerBound },
            wrapStart: { direction in
                if direction == .forward { return 0 }
                let length = try await source.length()
                return length > 0 ? length - 1 : nil
            },
            scan: { query, direction, anchor, limit, _ in
                let request = TextSearchQuery(text: query.text, caseSensitive: query.caseSensitive,
                                              wholeWord: query.wholeWord)
                let result = try await adapter.search(request,
                    direction: direction == .forward ? .forward : .backward,
                    fromByteOffset: anchor, exclusiveStartLimit: limit)
                switch result {
                case .found(let hit): return .found(hit)
                case .exhausted: return .exhausted
                case .cancelled: return .cancelled
                case .sourceChanged: return .sourceChanged
                }
            },
            validate: { hit, query in
                try await adapter.validate(hit, query: TextSearchQuery(
                    text: query.text, caseSensitive: query.caseSensitive, wholeWord: query.wholeWord))
            }
        )
        let surface = DocumentSearchSurface(frame: .zero)
        surface.translatesAutoresizingMaskIntoConstraints = false
        viewer.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: viewer.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: viewer.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: viewer.bottomAnchor,
                                            constant: -TerminalTheme.lineHeight),
            surface.heightAnchor.constraint(equalToConstant: DocumentSearchSurface.height),
        ])
        surface.onQueryChange = { [weak self] query in
            self?.searchGeneration &+= 1
            self?.discardPendingSearchReveal()
            self?.activeSearchRange = nil
            self?.activeSearchHit = nil
            self?.view?.activeSearchRange = nil
            self?.searchController?.setQuery(query)
            self?.request(.stay)
        }
        surface.onContinue = { [weak self] direction in self?.searchController?.continueSearch(direction) }
        surface.onDismiss = { [weak self] in
            self?.searchGeneration &+= 1
            self?.discardPendingSearchReveal()
            self?.searchController?.close()
            self?.searchController = nil
            self?.searchSurface = nil
            self?.activeSearchRange = nil
            self?.activeSearchHit = nil
            self?.view?.activeSearchRange = nil
            self?.view?.searchActive = false
            self?.request(.stay)
        }
        controller.onStatus = { [weak self, weak surface] status in
            surface?.update(status: status.displayText)
            switch status {
            case .noMatches, .sourceChanged, .error:
                guard let self else { return }
                self.searchGeneration &+= 1
                self.discardPendingSearchReveal()
                self.activeSearchHit = nil
                self.activeSearchRange = nil
                self.view?.activeSearchRange = nil
            case .idle, .searching, .found: break
            }
        }
        controller.onHit = { [weak self] hit, _ in
            guard let self else { return }
            self.activeSearchRange = hit.lowerBound..<hit.upperBound
            self.activeSearchHit = hit
            self.view?.activeSearchRange = self.activeSearchRange
            self.request(.reveal(byteOffset: hit.lowerBound))
        }
        searchController = controller
        searchSurface = surface
        viewer.searchActive = true
        controller.open(at: origin)
        surface.focus(contentResponder: viewer)
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
        wordContinuationTask?.cancel()
        wordContinuationTask = nil
        searchController?.close()
        searchController = nil
        searchSurface?.removeFromSuperview()
        searchSurface = nil
        activeSearchHit = nil
        contentSource = nil
        document = nil
        syntaxHighlighter = PlainTextSyntaxHighlighter.shared
        view?.removeFromSuperview()
        view = nil
        window?.makeFirstResponder(previousResponder)
        onClose?()
    }
}
