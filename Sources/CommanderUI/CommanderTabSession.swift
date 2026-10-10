import AppKit
import FileManagerCore

@MainActor
final class CommanderTabSession: NSObject {
    let id = UUID()
    let root = NSViewController()
    weak var window: NSWindow?
    var customTitle: String?
    var color: TabColor?
    var onTitleChanged: (() -> Void)?
    var title: String { customTitle ?? (activePane.state.directory.path as NSString).abbreviatingWithTildeInPath }
    var directories: [URL] { panes.map { $0.state.directory } }
    var canSwitch: Bool { !isExitPromptVisible && !fileOperationInProgress && window?.attachedSheet == nil }
    func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        shortcuts.shiftPressed = flags.contains(.shift)
        shortcuts.optionPressed = flags.contains(.option)
    }
    func restoreFocus() {
        window?.makeFirstResponder(editor?.responder ?? viewer?.view ?? activePane.view)
    }
    var isExitPromptVisible = false
    var onQuitRequested: () -> Void = { NSApp.terminate(nil) }
    private let panes: [PaneViewController]
    private var activeIndex = 0
    private let fileOpenCoordinator = FileOpenCoordinator()
    private let locationCoordinator: LocationCoordinator
    private let copyCoordinator = CopyCoordinator()
    private let renameCoordinator = RenameCoordinator()
    private let shortcuts = TerminalKeyBar()
    private let moveCoordinator = MoveCoordinator()
    private let createDirectoryCoordinator = CreateDirectoryCoordinator()
    private let deleteCoordinator = DeleteCoordinator()
    private var editor: FileEditorCoordinator?
    private var viewer: FileViewerCoordinator?
    var fileOperationInProgress: Bool { locationCoordinator.isPresented || fileOpenCoordinator.isBusy || editor?.isBusy == true || viewer?.isBusy == true || renameCoordinator.isBusy || moveCoordinator.isBusy || createDirectoryCoordinator.isBusy || copyCoordinator.isBusy || deleteCoordinator.isBusy }
    private var operationInProgress: Bool { isExitPromptVisible || fileOperationInProgress || viewer != nil || editor != nil }
    private var activePane: PaneViewController { panes[activeIndex] }

    init(window: NSWindow, directories: [URL], locationReader: any LocationReading) {
        self.window = window
        locationCoordinator = LocationCoordinator(reader: locationReader)
        let reader = LocalDirectoryReader()
        panes = [
            PaneViewController(title: "LEFT PANE", directory: directories[0], reader: reader),
            PaneViewController(title: "RIGHT PANE", directory: directories[1], reader: reader),
        ]
        super.init()
        let rootView = AppearanceObservingView()
        root.view = rootView
        rootView.onAppearanceChanged = { [weak window] in window?.backgroundColor = TerminalTheme.windowBackground }
        for pane in panes { root.addChild(pane) }

        shortcuts.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .leftLocations: self.chooseLocation(for: 0)
            case .rightLocations: self.chooseLocation(for: 1)
            case .viewFile: self.viewSelected()
            case .editFile: self.editSelected()
            case .createFile: self.createFile()
            case .copy: self.copySelected()
            case .move: self.moveSelected()
            case .rename: self.renameSelected()
            case .createDirectory: self.createDirectory()
            case .delete: self.deleteSelected()
            case .quit: self.onQuitRequested()
            }
        }
        let left = panes[0].view
        let right = panes[1].view
        // Explicit edge constraints make the panes fill the content area, independently
        // of label intrinsic widths and NSStackView cross-axis alignment behavior.
        for child in [left, right, shortcuts] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(child)
        }
        let paneInset: CGFloat = 2
        let paneSpacing: CGFloat = 2
        let keyBarInset: CGFloat = 0
        let keyBarGap: CGFloat = 0
        NSLayoutConstraint.activate([
            shortcuts.heightAnchor.constraint(equalToConstant: TerminalTheme.lineHeight),
            shortcuts.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: keyBarInset),
            shortcuts.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -keyBarInset),
            shortcuts.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -keyBarInset),
            left.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: paneInset),
            left.topAnchor.constraint(equalTo: root.view.topAnchor, constant: paneInset),
            left.bottomAnchor.constraint(equalTo: shortcuts.topAnchor, constant: -keyBarGap),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: paneSpacing),
            right.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -paneInset),
            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        for (index, pane) in panes.enumerated() {
            pane.onDirectoryChanged = { [weak self] in self?.onTitleChanged?() }
            pane.onAction = { [weak self] action in self?.handle(action, from: index) }
        }
    }

    func start() {
        for pane in panes { pane.load(pane.state.directory) }
        activate(0)
    }

    private func activate(_ index: Int) {
        activeIndex = index
        onTitleChanged?()
        for (paneIndex, pane) in panes.enumerated() { pane.setActive(paneIndex == index) }
        if window?.firstResponder !== panes[index].view { panes[index].focus() }
    }

    private func handle(_ action: PaneAction, from index: Int) {
        switch action {
        case .activate:
            activeIndex = index
            onTitleChanged?()
            for (paneIndex, pane) in panes.enumerated() { pane.setActive(paneIndex == index) }
        case .switchPane: activate(1 - index)
        case .matchDirectory: matchDirectory(nil)
        case .locations(let paneIndex): chooseLocation(for: paneIndex)
        case .open:
            guard !operationInProgress, !panes[index].isLoading, let window,
                  let row = panes[index].state.selectedRow else { return }
            if row.isDirectory { panes[index].openSelected() }
            else { fileOpenCoordinator.begin(file: row.url, window: window) }
        case .parent: panes[index].goToParent()
        case .viewFile: viewSelected()
        case .editFile: editSelected()
        case .createFile: createFile()
        case .copy: copySelected()
        case .move: moveSelected()
        case .rename: renameSelected()
        case .createDirectory: createDirectory()
        case .delete: deleteSelected()
        case .quit: self.onQuitRequested()
        }
    }

    private func renameSelected() {
        guard let window, !operationInProgress, !activePane.isLoading,
              case .entry(let entry) = activePane.state.selectedRow else { return }
        let source = entry.url
        let canonicalSource = source.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(source.lastPathComponent)
        renameCoordinator.begin(source: source, window: window) { [weak self] destination in
            guard let self else { return }
            for pane in self.panes {
                let directory = pane.state.directory.resolvingSymlinksInPath()
                if entry.isDirectory && !entry.isSymbolicLink &&
                    (directory == canonicalSource || directory.path.hasPrefix(canonicalSource.path + "/")) {
                    let suffix = String(directory.path.dropFirst(canonicalSource.path.count))
                    pane.load(URL(fileURLWithPath: destination.path + suffix))
                } else {
                    let sameParent = directory == canonicalSource.deletingLastPathComponent()
                    let selected = pane.state.selectedRow?.url.lastPathComponent == source.lastPathComponent
                    pane.load(pane.state.directory, preferredSelection: sameParent && selected
                        ? pane.state.directory.appendingPathComponent(destination.lastPathComponent) : pane.state.selectedRow?.url)
                }
            }
        }
    }

    @objc func matchDirectory(_ sender: Any?) {
        guard !operationInProgress, !activePane.isLoading else { return }
        let destination = panes[1 - activeIndex]
        destination.load(activePane.state.directory, preferredSelection: activePane.state.selectedRow?.url)
    }

    func closeViewer() { viewer?.close() }

    func prepareForTermination(_ completion: @escaping (Bool) -> Void) {
        if let editor { editor.requestClose(completion: completion) }
        else { completion(true) }
    }

    private func createFile() {
        guard let window, !operationInProgress, !activePane.isLoading else { return }
        let coordinator = FileEditorCoordinator()
        coordinator.onClose = { [weak self] in
            self?.editor = nil
            self?.panes.forEach { $0.refresh() }
        }
        editor = coordinator
        coordinator.presentNewFile(directory: activePane.state.directory, window: window)
    }

    private func editSelected() {
        guard let window, !operationInProgress, !activePane.isLoading,
              case .entry(let entry) = activePane.state.selectedRow, !entry.isDirectory else { return }
        let coordinator = FileEditorCoordinator()
        coordinator.onClose = { [weak self] in
            self?.editor = nil
            self?.panes.forEach { $0.refresh() }
        }
        editor = coordinator
        coordinator.present(url: entry.url, window: window)
    }

    private func viewSelected() {
        guard let window, !operationInProgress, !activePane.isLoading,
              case .entry(let entry) = activePane.state.selectedRow, !entry.isDirectory else { return }
        let coordinator = FileViewerCoordinator()
        coordinator.onClose = { [weak self] in
            self?.viewer = nil
            // Opening may have downloaded an iCloud file; refresh the snapshot.
            self?.panes.forEach { $0.refresh() }
        }
        viewer = coordinator
        coordinator.present(url: entry.url, window: window)
    }

    private func createDirectory() {
        let sourcePane = activePane
        guard let window, !operationInProgress, !sourcePane.isLoading else { return }
        let parent = sourcePane.state.directory
        createDirectoryCoordinator.begin(directory: parent, window: window) { [weak self] created in
            guard let self else { return }
            for pane in self.panes where pane.state.directory.resolvingSymlinksInPath() == parent.resolvingSymlinksInPath() {
                let selection = pane === sourcePane ? pane.state.directory.appendingPathComponent(created.lastPathComponent) : pane.state.selectedRow?.url
                pane.load(pane.state.directory, preferredSelection: selection)
            }
        }
    }

    private func copySelected() {
        let sourcePane = activePane
        let destinationPane = panes[1 - activeIndex]
        guard let window, !sourcePane.isLoading, !destinationPane.isLoading,
              !operationInProgress, let row = sourcePane.state.selectedRow else { return }
        let entries: [FileEntry]
        if !sourcePane.state.markedEntries.isEmpty { entries = sourcePane.state.markedEntries }
        else if case .entry(let entry) = row { entries = [entry] }
        else { return }
        guard entries.allSatisfy({ !$0.isDirectory || $0.isSymbolicLink }) else {
            sourcePane.showStatus("Folder copying is not supported yet; unmark folders before copying", isError: true)
            return
        }
        copyCoordinator.begin(sources: entries.map(\.url), directory: destinationPane.state.directory, window: window,
            onStart: { sourcePane.showStatus("Copying \(entries.count) file(s)…") },
            onFinish: { [weak self] result in
                guard let self else { return }
                if case .success = result { sourcePane.clearMarks() }
                // A stopped batch may already have published some complete files.
                // Refresh both panes even on cancellation or failure; keep marks then.
                for pane in self.panes { pane.refresh() }
            })
    }

    private func moveSelected() {
        let sourcePane = activePane
        let destinationPane = panes[1 - activeIndex]
        guard let window, !operationInProgress, !sourcePane.isLoading, !destinationPane.isLoading else { return }
        let entries: [FileEntry]
        if !sourcePane.state.markedEntries.isEmpty { entries = sourcePane.state.markedEntries }
        else if case .entry(let entry) = sourcePane.state.selectedRow { entries = [entry] }
        else { return }
        // Capture resolved locations before moving folders, for panes open inside them.
        let directories = panes.map { $0.state.directory.resolvingSymlinksInPath() }
        let folders = entries.filter { $0.isDirectory && !$0.isSymbolicLink }.map { ($0.url, $0.url.resolvingSymlinksInPath()) }
        moveCoordinator.begin(sources: entries.map(\.url), directory: destinationPane.state.directory, window: window) { [weak self] outcome in
            guard let self else { return }
            if outcome.succeeded { sourcePane.clearMarks() }
            let removed = Set(outcome.completed.map(\.source))
            for (index, pane) in self.panes.enumerated() {
                if let folder = folders.first(where: { removed.contains($0.0) &&
                    (directories[index] == $0.1 || directories[index].path.hasPrefix($0.1.path + "/")) }),
                   let moved = outcome.completed.first(where: { $0.source == folder.0 }) {
                    let suffix = String(directories[index].path.dropFirst(folder.1.path.count))
                    pane.load(URL(fileURLWithPath: moved.destination.path + suffix))
                } else {
                    let remaining = pane.state.rows.filter { !removed.contains($0.url) }
                    let fallback = remaining.isEmpty ? nil : remaining[min(pane.state.selectedIndex ?? 0, remaining.count - 1)].url
                    let current = pane.state.selectedRow?.url
                    pane.load(pane.state.directory, preferredSelection: current.map { removed.contains($0) } == true ? fallback : current)
                }
            }
        }
    }

    private func deleteSelected() {
        let sourcePane = activePane
        guard let window, !operationInProgress, !sourcePane.isLoading else { return }
        let entries: [FileEntry]
        if !sourcePane.state.markedEntries.isEmpty { entries = sourcePane.state.markedEntries }
        else if case .entry(let entry) = sourcePane.state.selectedRow { entries = [entry] }
        else { return }
        let parent = sourcePane.state.directory
        let folders = entries.filter { $0.isDirectory && !$0.isSymbolicLink }
        deleteCoordinator.begin(items: entries.map(\.url), includesDirectories: !folders.isEmpty,
            window: window, onStart: { sourcePane.showStatus("Moving \(entries.count) item(s) to Trash…") },
            onFinish: { [weak self] result in
                guard let self else { return }
                let completed: [URL]
                switch result {
                case .success(let items):
                    completed = items
                    sourcePane.clearMarks()
                case .failure(let error):
                    completed = (error as? FileTrashBatchError)?.completed ?? []
                }
                let removed = Set(completed)
                let names = Set(completed.map(\.lastPathComponent))
                for pane in self.panes {
                    let directory = pane.state.directory
                    if directory.standardizedFileURL == parent.standardizedFileURL ||
                       directory.resolvingSymlinksInPath() == parent.resolvingSymlinksInPath() {
                        let index = pane.state.selectedIndex ?? 0
                        let remaining = pane.state.rows.filter { !names.contains($0.url.lastPathComponent) }
                        let fallback = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].url
                        let selected = pane.state.selectedRow?.url
                        let selection = selected.map { names.contains($0.lastPathComponent) } == true ? fallback : selected
                        pane.load(directory, preferredSelection: selection)
                    } else if folders.contains(where: { removed.contains($0.url) &&
                        (directory.path == $0.url.path || directory.path.hasPrefix($0.url.path + "/")) }) {
                        pane.load(parent)
                    }
                }
            })
    }

    @objc func leftLocations(_ sender: Any?) { chooseLocation(for: 0) }
    @objc func rightLocations(_ sender: Any?) { chooseLocation(for: 1) }

    private func chooseLocation(for index: Int) {
        guard let window, !operationInProgress, panes.indices.contains(index) else { return }
        locationCoordinator.begin(paneName: index == 0 ? "Left pane" : "Right pane", window: window) { [weak self] url in
            guard let self else { return }
            self.panes[index].load(url)
            self.activate(index)
        }
    }

    @objc func refresh(_ sender: Any?) {
        if let viewer { viewer.request(.stay); return }
        guard !operationInProgress else { return }
        activePane.refresh()
    }
    @objc func goHome(_ sender: Any?) { guard !operationInProgress else { return }; activePane.load(FileManager.default.homeDirectoryForCurrentUser) }
    @objc func toggleHidden(_ sender: Any?) {
        guard !operationInProgress else { return }
        activePane.showHidden.toggle()
        activePane.refresh()
    }

    @objc func goToFolder(_ sender: Any?) {
        guard let window, !operationInProgress else { return }
        let pane = activePane
        let alert = NSAlert()
        alert.messageText = "Go to folder"
        alert.informativeText = "Enter an absolute path, a path relative to this pane, or use ~ for your home folder."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: pane.state.directory.path)
        field.frame = NSRect(x: 0, y: 0, width: 440, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn, !field.stringValue.isEmpty {
                let path = (field.stringValue as NSString).expandingTildeInPath
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : pane.state.directory.appendingPathComponent(path)
                pane.load(url.standardizedFileURL)
            }
            pane.focus()
        }
    }
}

