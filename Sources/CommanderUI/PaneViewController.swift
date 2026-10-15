import AppKit
import FileManagerCore

enum PaneAction {
    case locations(Int)
    case activate, switchPane, matchDirectory, open, parent, copy, move, rename, delete, viewFile, editFile, createFile, quit, createDirectory
}

/// Coordinates filesystem snapshots and navigation, without knowing how rows are drawn.
@MainActor
final class PaneViewController: NSViewController {
    private(set) var state: PaneState
    private let reader: any DirectoryReading
    private let terminalView: TerminalPaneView
    private var loadTask: Task<Void, Never>?
    private var requestID = UUID()
    private var directoryMonitor: DirectoryMonitor?
    private var monitorTask: Task<Void, Never>?
    private var monitoredDirectory: URL?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private(set) var isLoading = false
    private var status = ""
    private var listingStatus = ""
    private var isError = false
    var showHidden = false
    var onDirectoryChanged: (() -> Void)?
    var onAction: ((PaneAction) -> Void)?

    init(title: String, directory: URL, reader: any DirectoryReading) {
        state = PaneState(directory: directory)
        self.reader = reader
        terminalView = TerminalPaneView(name: title)
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        loadTask?.cancel()
        refreshTask?.cancel()
        monitorTask?.cancel()
    }

    @objc private func applicationDidBecomeActive() {
        guard isViewLoaded else { return }
        scheduleRefresh()
    }

    private func monitor(_ directory: URL) {
        let directory = directory.standardizedFileURL
        guard monitoredDirectory != directory || (directoryMonitor == nil && monitorTask == nil) else { return }
        monitorTask?.cancel()
        directoryMonitor = nil
        monitoredDirectory = directory
        monitorTask = Task { [weak self] in
            let monitor = await Task.detached(priority: .utility) { [weak self] in
                DirectoryMonitor(directory: directory) { [weak self] in
                    guard let self, self.monitoredDirectory == directory else { return }
                    self.scheduleRefresh()
                }
            }.value
            guard !Task.isCancelled, let self, self.monitoredDirectory == directory else { return }
            self.monitorTask = nil
            self.directoryMonitor = monitor
            // Close the gap between the initial snapshot and watcher registration.
            if monitor != nil { self.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        // Do not postpone indefinitely when a directory changes continuously.
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard let self else { return }
            self.refreshTask = nil
            if self.loadTask != nil {
                self.refreshPending = true
            } else {
                self.load(self.state.directory, automatic: true)
            }
        }
    }

    override func loadView() {
        view = terminalView
        terminalView.onInput = { [weak self] input in
            guard let self else { return }
            switch input {
            case .toggleMark:
                guard !self.isLoading else { return }
                self.state.toggleMark()
                self.render()
            case .extendSelection(let index):
                guard !self.isLoading else { return }
                self.state.extendSelection(to: index)
                self.render()
            case .endRangeSelection: self.state.endRangeSelection()
            case .activate: self.onAction?(.activate)
            case .switchPane: self.onAction?(.switchPane)
            case .matchDirectory: self.onAction?(.matchDirectory)
            case .locations(let index): self.onAction?(.locations(index))
            case .open: self.onAction?(.open)
            case .parent: self.onAction?(.parent)
            case .viewFile: self.onAction?(.viewFile)
            case .editFile: self.onAction?(.editFile)
            case .createFile: self.onAction?(.createFile)
            case .copy: self.onAction?(.copy)
            case .move: self.onAction?(.move)
            case .rename: self.onAction?(.rename)
            case .createDirectory: self.onAction?(.createDirectory)
            case .delete: self.onAction?(.delete)
            case .quit: self.onAction?(.quit)
            case .select(let index):
                self.state.select(index)
                self.render()
            }
        }
        render()
    }

    private func render() {
        let marks = state.markedURLs.count
        let displayStatus = !isError && !isLoading && marks > 0 ? "\(status) · \(marks) selected" : status
        terminalView.update(state: state, status: displayStatus, isError: isError)
    }
    func setActive(_ active: Bool) { terminalView.isActive = active }
    func focus() { view.window?.makeFirstResponder(terminalView) }

    func load(_ directory: URL, preferredSelection: URL? = nil) {
        load(directory, preferredSelection: preferredSelection, automatic: false)
    }

    private func load(_ directory: URL, preferredSelection: URL? = nil, automatic: Bool, session: FileSystemSession? = nil, archiveURL: URL? = nil) {
        _ = view
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        loadTask?.cancel()
        // Register asynchronously; completion requests another snapshot to cover changes during setup.
        if directory.isFileURL && archiveURL == nil { monitor(directory) }
        else {
            monitorTask?.cancel(); monitorTask = nil
            directoryMonitor = nil; monitoredDirectory = nil
        }
        let id = UUID()
        requestID = id
        if !automatic {
            isLoading = true
            isError = false
            status = "Loading…"
            render()
        }
        let session = session ?? (directory.isFileURL
            ? FileSystemSession(fileSystem: LocalFileSystem(reader: reader), path: FileSystemPath(directory))
            : state.session.navigating(to: directory))
        let hidden = showHidden
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Result {
                    let target = try archiveURL.map { try ArchiveFileSystem(url: $0).session } ?? session
                    return (try target.fileSystem.snapshot(at: target.path, showHidden: hidden), target)
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.loadTask = nil
            self.isLoading = false
            switch result {
            case .success(let (snapshot, target)):
                let entries = snapshot.entries
                // Capture the cursor at completion: the user can move it during a background read.
                let selection = automatic ? self.state.selectedRow?.url : preferredSelection
                self.state.replace(directory: target.path.url, entries: entries, preferredSelection: selection, directoryModified: snapshot.modified, session: target)
                self.onDirectoryChanged?()
                let wasListingStatus = self.status == self.listingStatus
                self.listingStatus = "\(entries.count) items\(hidden ? " · hidden shown" : "")\(target.fileSystem.supportsFileOperations ? "" : " · read-only archive")"
                if !automatic || wasListingStatus || self.isError {
                    self.status = self.listingStatus
                    self.isError = false
                }
            case .failure(let error):
                self.status = "Cannot open folder: \(error.localizedDescription)"
                self.isError = true
                if self.state.directory.isFileURL { self.monitor(self.state.directory) }
            }
            self.render()
            if self.refreshPending {
                self.refreshPending = false
                self.scheduleRefresh()
            }
        }
    }

    func load(session: FileSystemSession, preferredSelection: URL? = nil) {
        load(session.path.url, preferredSelection: preferredSelection, automatic: false, session: session)
    }

    func restoreListingStatus() { showStatus(listingStatus) }

    func showStatus(_ message: String, isError: Bool = false) {
        status = message
        self.isError = isError
        render()
    }

    func refresh() { load(state.directory, preferredSelection: state.selectedRow?.url) }
    func clearMarks() { state.clearMarks(); render() }

    var canBrowseSelected: Bool {
        guard let row = state.selectedRow else { return false }
        return row.isDirectory || (state.directory.isFileURL && ArchiveFileSystem.recognizes(row.url))
    }

    func openSelected() {
        guard !isLoading, let row = state.selectedRow else { return }
        if row.isDirectory {
            if case .parent = row { goToParent() }
            else { load(row.url) }
        } else if state.directory.isFileURL && ArchiveFileSystem.recognizes(row.url) {
            load(row.url, automatic: false, archiveURL: row.url)
        }
    }

    func goToParent() {
        guard !isLoading, let parent = state.parent else { return }
        load(parent, preferredSelection: state.session.path.parent == nil ? state.session.exitSelection : state.directory)
    }
}
