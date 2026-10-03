import AppKit
import FileManagerCore

enum PaneAction {
    case activate, switchPane, matchDirectory, open, parent, copy, move, rename, delete, viewFile, editFile, quit, createDirectory
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
    private var monitoredDirectory: URL?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private(set) var isLoading = false
    private var status = ""
    private var listingStatus = ""
    private var isError = false
    var showHidden = false
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
    }

    @objc private func applicationDidBecomeActive() {
        guard isViewLoaded else { return }
        scheduleRefresh()
    }

    private func monitor(_ directory: URL) {
        let directory = directory.standardizedFileURL
        guard monitoredDirectory != directory || directoryMonitor == nil else { return }
        directoryMonitor = nil
        monitoredDirectory = directory
        directoryMonitor = DirectoryMonitor(directory: directory) { [weak self] in
            guard let self, self.monitoredDirectory == directory else { return }
            self.scheduleRefresh()
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
            case .open: self.onAction?(.open)
            case .parent: self.onAction?(.parent)
            case .viewFile: self.onAction?(.viewFile)
            case .editFile: self.onAction?(.editFile)
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

    private func load(_ directory: URL, preferredSelection: URL? = nil, automatic: Bool) {
        _ = view
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        loadTask?.cancel()
        // Start observing before taking the snapshot so changes during a read are not lost.
        monitor(directory)
        let id = UUID()
        requestID = id
        if !automatic {
            isLoading = true
            isError = false
            status = "Loading…"
            render()
        }
        let reader = self.reader
        let hidden = showHidden
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let entries = try reader.entries(at: directory, showHidden: hidden)
                    let modified = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    return (entries, modified)
                }
            }.value
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.loadTask = nil
            self.isLoading = false
            switch result {
            case .success(let (entries, modified)):
                // Capture the cursor at completion: the user can move it during a background read.
                let selection = automatic ? self.state.selectedRow?.url : preferredSelection
                self.state.replace(directory: directory, entries: entries, preferredSelection: selection, directoryModified: modified)
                let wasListingStatus = self.status == self.listingStatus
                self.listingStatus = "\(entries.count) items\(hidden ? " · hidden shown" : "")"
                if !automatic || wasListingStatus || self.isError {
                    self.status = self.listingStatus
                    self.isError = false
                }
            case .failure(let error):
                self.status = "Cannot open folder: \(error.localizedDescription)"
                self.isError = true
                self.monitor(self.state.directory)
            }
            self.render()
            if self.refreshPending {
                self.refreshPending = false
                self.scheduleRefresh()
            }
        }
    }

    func restoreListingStatus() { showStatus(listingStatus) }

    func showStatus(_ message: String, isError: Bool = false) {
        status = message
        self.isError = isError
        render()
    }

    func refresh() { load(state.directory, preferredSelection: state.selectedRow?.url) }
    func clearMarks() { state.clearMarks(); render() }

    func openSelected() {
        guard !isLoading, let row = state.selectedRow else { return }
        if row.isDirectory {
            if case .parent = row { goToParent() }
            else { load(row.url) }
        }
    }

    func goToParent() {
        guard !isLoading, let parent = state.parent else { return }
        load(parent, preferredSelection: state.directory)
    }
}
