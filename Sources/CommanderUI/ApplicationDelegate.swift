import AppKit
import FileManagerCore
import Sparkle

@MainActor
public final class ApplicationDelegate: NSObject, NSApplicationDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var mainWindow: CommanderWindowController?
    private let exitCoordinator = ExitCoordinator()
    private var updaterController: SPUStandardUpdaterController!
    private var updateAccessory: NSTitlebarAccessoryViewController?

    public override init() {
        super.init()
        // Delay starting Sparkle until the main window exists so scheduled updates can
        // be represented by a quiet title-bar reminder rather than an alert.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Load the bundled icon directly so a cached development-build icon in
        // Launch Services cannot leave the running app with the generic Dock tile.
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let iconURL = Bundle.main.resourceURL?.appendingPathComponent(iconName),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        installMenu()
        let controller = CommanderWindowController()
        mainWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
        updaterController.startUpdater()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = mainWindow, let window = controller.window else { return .terminateNow }
        controller.isExitPromptVisible = true
        exitCoordinator.request(window: window, operationInProgress: controller.fileOperationInProgress) { confirmed in
            controller.isExitPromptVisible = false
            if confirmed { controller.prepareForTermination { sender.reply(toApplicationShouldTerminate: $0) } }
            else { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled checks should never interrupt the user with a window.
        false
    }

    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // User-initiated checks are shown by Sparkle normally. For scheduled checks,
        // expose the available update quietly in the main window title bar.
        guard !handleShowingUpdate, updateAccessory == nil,
              let window = mainWindow?.window else { return }

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = UpdateAvailableButton(
            target: updaterController,
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        )
        window.addTitlebarAccessoryViewController(accessory)
        updateAccessory = accessory
    }

    public func standardUserDriverWillFinishUpdateSession() {
        updateAccessory?.removeFromParent()
        updateAccessory = nil
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Commander")
        appMenu.addItem(withTitle: "About Commander", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let checkForUpdates = appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Commander", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Commander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let navigation = NSMenu(title: "Navigate")
        navigation.addItem(withTitle: "Go to Folder…", action: #selector(CommanderWindowController.goToFolder(_:)), keyEquivalent: "l")
        navigation.addItem(withTitle: "Left Pane Locations…", action: #selector(CommanderWindowController.leftLocations(_:)), keyEquivalent: "1")
        navigation.addItem(withTitle: "Right Pane Locations…", action: #selector(CommanderWindowController.rightLocations(_:)), keyEquivalent: "2")
        let matchDirectory = navigation.addItem(withTitle: "Open Current Directory in Other Pane",
            action: #selector(CommanderWindowController.matchDirectory(_:)), keyEquivalent: "d")
        matchDirectory.keyEquivalentModifierMask = [.command]
        navigation.addItem(withTitle: "Go Home", action: #selector(CommanderWindowController.goHome(_:)), keyEquivalent: "~")
        navigation.addItem(withTitle: "Refresh", action: #selector(CommanderWindowController.refresh(_:)), keyEquivalent: "r")
        navigation.addItem(withTitle: "Show Hidden Files", action: #selector(CommanderWindowController.toggleHidden(_:)), keyEquivalent: ".")
        let navigationItem = NSMenuItem()
        navigationItem.submenu = navigation
        menu.addItem(navigationItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}

@MainActor
final class CommanderWindowController: NSWindowController, NSWindowDelegate {
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
    var fileOperationInProgress: Bool { locationCoordinator.isPresented || fileOpenCoordinator.isBusy || editor?.isBusy == true || renameCoordinator.isBusy || moveCoordinator.isBusy || createDirectoryCoordinator.isBusy || copyCoordinator.isBusy || deleteCoordinator.isBusy }
    private var operationInProgress: Bool { isExitPromptVisible || fileOperationInProgress || viewer != nil || editor != nil }
    private var activePane: PaneViewController { panes[activeIndex] }

    init(locationReader: any LocationReading = LocalLocationReader()) {
        locationCoordinator = LocationCoordinator(reader: locationReader)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let reader = LocalDirectoryReader()
        panes = [
            PaneViewController(title: "LEFT PANE", directory: home, reader: reader),
            PaneViewController(title: "RIGHT PANE", directory: home, reader: reader),
        ]
        let window = CommanderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.title = "Commander"
        window.minSize = NSSize(width: 700, height: 380)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = NSViewController()
        let glass = NSVisualEffectView()
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        root.view = glass
        window.contentViewController = root

        for pane in panes { root.addChild(pane) }

        window.onModifiersChanged = { [weak self] flags in
            self?.shortcuts.shiftPressed = flags.contains(.shift)
            self?.shortcuts.optionPressed = flags.contains(.option)
        }
        shortcuts.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .leftLocations: self.chooseLocation(for: 0)
            case .rightLocations: self.chooseLocation(for: 1)
            case .viewFile: self.viewSelected()
            case .editFile: self.editSelected()
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
        // The panes draw their outer cyan border 2.5 pt inside views that are
        // themselves inset by 2 pt. Align the function-key bar to that border.
        let chromeInset: CGFloat = 4.5
        NSLayoutConstraint.activate([
            shortcuts.heightAnchor.constraint(equalToConstant: TerminalTheme.lineHeight),
            shortcuts.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: chromeInset),
            shortcuts.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -chromeInset),
            shortcuts.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -chromeInset),
            left.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 2),
            left.topAnchor.constraint(equalTo: root.view.topAnchor, constant: 2),
            left.bottomAnchor.constraint(equalTo: shortcuts.topAnchor, constant: -2),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 2),
            right.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -2),
            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        for (index, pane) in panes.enumerated() {
            pane.onAction = { [weak self] action in self?.handle(action, from: index) }
        }
        window.center()
        window.setFrameAutosaveName("CommanderMainWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onQuitRequested()
        return false // The window stays visible until application termination is confirmed.
    }

    func start() {
        for pane in panes { pane.load(pane.state.directory) }
        activate(0)
    }

    private func activate(_ index: Int) {
        activeIndex = index
        for (paneIndex, pane) in panes.enumerated() { pane.setActive(paneIndex == index) }
        if window?.firstResponder !== panes[index].view { panes[index].focus() }
    }

    private func handle(_ action: PaneAction, from index: Int) {
        switch action {
        case .activate:
            activeIndex = index
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
        case .copy: copySelected()
        case .move: moveSelected()
        case .rename: renameSelected()
        case .createDirectory: createDirectory()
        case .delete: deleteSelected()
        case .quit: self.onQuitRequested()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcuts.shiftPressed = false
        shortcuts.optionPressed = false
    }
    func windowDidBecomeKey(_ notification: Notification) {
        shortcuts.shiftPressed = NSEvent.modifierFlags.contains(.shift)
        shortcuts.optionPressed = NSEvent.modifierFlags.contains(.option)
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

    func prepareForTermination(_ completion: @escaping (Bool) -> Void) {
        if let editor { editor.requestClose(completion: completion) }
        else { completion(true) }
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

/// Observes modifiers before dispatch, including while a dialog owns keyboard focus.
@MainActor
private final class CommanderWindow: NSWindow {
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        onModifiersChanged?(event.modifierFlags)
        super.sendEvent(event)
    }
}
