import AppKit
import FileManagerCore

@MainActor
final class CommanderWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private(set) var tabs: [CommanderTabSession] = []
    private(set) var selectedIndex = 0
    var selectedTab: CommanderTabSession { tabs[selectedIndex] }
    var onQuitRequested: () -> Void = { NSApp.terminate(nil) }
    var isExitPromptVisible = false {
        didSet { tabs.forEach { $0.isExitPromptVisible = isExitPromptVisible } }
    }
    var fileOperationInProgress: Bool { tabs.contains { $0.fileOperationInProgress } }
    private let locationReader: any LocationReading
    private let tabStrip = CommanderTabStrip()
    private let tabAccessory = NSTitlebarAccessoryViewController()
    private(set) var tabPlacement: TabPlacement
    private var closingTab = false
    private var preparingToTerminate = false
    private var canChangeTab: Bool { !closingTab && !preparingToTerminate && selectedTab.canSwitch }

    init(locationReader: any LocationReading = LocalLocationReader()) {
        self.locationReader = locationReader
        tabPlacement = TabPlacement(rawValue: UserDefaults.standard.string(forKey: TabPlacement.preferenceKey) ?? "") ?? .titlebar
        let window = CommanderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Commander"
        window.minSize = NSSize(width: 700, height: 380)
        window.backgroundColor = TerminalTheme.windowBackground
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tab = makeTab(directories: [home, home])
        tabs = [tab]
        window.contentViewController = tab.root
        window.onModifiersChanged = { [weak self] flags in self?.selectedTab.updateModifiers(flags) }
        tabStrip.onSelect = { [weak self] id in self?.selectTab(id: id) }
        tabStrip.onClose = { [weak self] id in
            guard let self, self.canChangeTab else { return }
            self.selectTab(id: id)
            self.closeTab(nil)
        }
        tabStrip.onRename = { [weak self] id in
            guard let self, self.canChangeTab else { return }
            self.selectTab(id: id)
            self.renameTab(nil)
        }
        tabStrip.onCloseOthers = { [weak self] id in self?.closeOtherTabs(id: id) }
        tabStrip.onCloseRight = { [weak self] id in self?.closeTabsToRight(id: id) }
        tabStrip.onColor = { [weak self] id, color in self?.setTabColor(color, for: id) }
        tabStrip.canInteract = { [weak self] in self?.canChangeTab == true }
        tabStrip.onNew = { [weak self] in self?.newTab(nil) }
        installTabStrip()
        updateTabs()
        window.center()
        window.setFrameAutosaveName("CommanderMainWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeTab(directories: [URL]) -> CommanderTabSession {
        let tab = CommanderTabSession(window: window!, directories: directories, locationReader: locationReader)
        tab.onQuitRequested = { [weak self] in self?.onQuitRequested() }
        tab.onTitleChanged = { [weak self] in self?.updateTabs(revealSelection: false) }
        return tab
    }

    func start() { selectedTab.start() }

    @objc func newTab(_ sender: Any?) {
        guard canChangeTab else { return }
        let tab = makeTab(directories: selectedTab.directories)
        tabs.append(tab)
        displayTab(at: tabs.count - 1)
        tab.start()
    }

    func selectTab(id: UUID) {
        guard canChangeTab, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        displayTab(at: index)
    }

    private func displayTab(at index: Int) {
        guard let window else { return }
        if index != selectedIndex || window.contentViewController !== tabs[index].root {
            selectedTab.updateModifiers([])
            selectedIndex = index
            attach(selectedTab)
            selectedTab.updateModifiers(NSEvent.modifierFlags)
            selectedTab.restoreFocus()
        }
        updateTabs()
    }

    private func attach(_ tab: CommanderTabSession) {
        guard let window else { return }
        // AppKit may resize a window to a newly assigned content controller. Tab
        // changes must preserve the outer frame, including a bottom title-bar accessory.
        let frame = window.frame
        tab.root.view.frame = window.contentView?.bounds ?? .zero
        window.contentViewController = tab.root
        window.setFrame(frame, display: true)
    }

    @objc func nextTab(_ sender: Any?) {
        guard canChangeTab else { return }
        displayTab(at: (selectedIndex + 1) % tabs.count)
    }
    @objc func previousTab(_ sender: Any?) {
        guard canChangeTab else { return }
        displayTab(at: (selectedIndex + tabs.count - 1) % tabs.count)
    }

    @objc func closeTab(_ sender: Any?) {
        guard canChangeTab else { return }
        guard tabs.count > 1 else { onQuitRequested(); return }
        let neighbor = tabs[selectedIndex == tabs.count - 1 ? selectedIndex - 1 : selectedIndex + 1].id
        closeTabs(ids: [selectedTab.id], selecting: neighbor)
    }

    func closeOtherTabs(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        closeTabs(ids: tabs.filter { $0.id != id }.map(\.id), selecting: id)
    }

    func closeTabsToRight(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTabs(ids: tabs.dropFirst(index + 1).map(\.id), selecting: id)
    }

    private func closeTabs(ids: [UUID], selecting survivor: UUID) {
        guard canChangeTab, !ids.isEmpty,
              tabs.filter({ ids.contains($0.id) }).allSatisfy({ $0.canSwitch }) else { return }
        closingTab = true
        func closeNext(_ offset: Int) {
            guard offset < ids.count else {
                closingTab = false
                if let index = tabs.firstIndex(where: { $0.id == survivor }) { displayTab(at: index) }
                return
            }
            guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == ids[offset] }) else {
                closeNext(offset + 1)
                return
            }
            displayTab(at: index)
            let tab = selectedTab
            tab.prepareForTermination { [weak self] confirmed in
                guard let self else { return }
                guard confirmed else {
                    self.closingTab = false
                    return // Leave the editor and all remaining tabs intact on Cancel.
                }
                tab.closeViewer()
                self.tabs.remove(at: index)
                self.selectedIndex = min(index, self.tabs.count - 1)
                self.attach(self.selectedTab)
                self.selectedTab.restoreFocus()
                self.selectedTab.updateModifiers(NSEvent.modifierFlags)
                self.updateTabs()
                closeNext(offset + 1)
            }
        }
        closeNext(0)
    }

    func setTabColor(_ color: TabColor?, for id: UUID) {
        guard canChangeTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.color = color
        updateTabs(revealSelection: false)
    }

    @objc func renameTab(_ sender: Any?) {
        guard canChangeTab, let window else { return }
        let tab = selectedTab
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave the name empty to follow the active pane’s path."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: tab.customTitle ?? tab.title)
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let responder = window.firstResponder
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.setTabTitle(field.stringValue, for: tab.id)
            }
            window.makeFirstResponder(responder)
        }
    }

    func setTabTitle(_ title: String, for id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = name.isEmpty ? nil : name
        updateTabs()
    }

    func prepareForTermination(_ completion: @escaping (Bool) -> Void) {
        guard !preparingToTerminate else { completion(false); return }
        preparingToTerminate = true
        func prepare(_ index: Int) {
            guard index < tabs.count else {
                preparingToTerminate = false
                completion(true)
                return
            }
            displayTab(at: index)
            tabs[index].prepareForTermination { [weak self] confirmed in
                guard let self else { completion(false); return }
                if confirmed { prepare(index + 1) }
                else {
                    self.preparingToTerminate = false
                    // Keep the tab with the unsaved editor visible on cancellation.
                    self.updateTabs()
                    completion(false)
                }
            }
        }
        if tabs.count == 1 {
            selectedTab.prepareForTermination { [weak self] confirmed in
                self?.preparingToTerminate = false
                completion(confirmed)
            }
        } else {
            prepare(0)
        }
    }

    @objc func selectTabPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let placement = TabPlacement(rawValue: raw) else { return }
        setTabPlacement(placement)
    }
    func setTabPlacement(_ placement: TabPlacement) {
        tabPlacement = placement
        UserDefaults.standard.set(placement.rawValue, forKey: TabPlacement.preferenceKey)
        installTabStrip()
    }
    private func installTabStrip() {
        guard let window else { return }
        tabAccessory.removeFromParent()
        guard tabs.count > 1 else {
            window.titleVisibility = .visible
            return
        }
        tabAccessory.layoutAttribute = tabPlacement == .titlebar ? .right : .bottom
        tabStrip.alignsWithWindowControls = tabPlacement == .titlebar
        tabAccessory.view = tabStrip
        window.titleVisibility = tabPlacement == .titlebar ? .hidden : .visible
        layoutTabStrip()
        window.addTitlebarAccessoryViewController(tabAccessory)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        tabStrip.needsLayout = true
        tabStrip.layoutSubtreeIfNeeded()
        tabStrip.revealSelection()
    }
    func layoutTabStrip() {
        guard let window else { return }
        let otherWidth = window.titlebarAccessoryViewControllers
            .filter { $0 !== tabAccessory && $0.layoutAttribute == .right }
            .reduce(CGFloat(0)) { $0 + $1.view.frame.width }
        let reserved: CGFloat = tabPlacement == .titlebar ? 100 + otherWidth : 0
        tabStrip.setFrameSize(NSSize(width: max(180, window.frame.width - reserved), height: CommanderTabStrip.preferredHeight))
        tabStrip.layoutSubtreeIfNeeded()
    }
    private func updateTabs(revealSelection: Bool = true) {
        let isInstalled = window?.titlebarAccessoryViewControllers.contains { $0 === tabAccessory } == true
        if isInstalled != (tabs.count > 1) { installTabStrip() }
        tabStrip.update(tabs: tabs.map { ($0.id, $0.title) }, selected: selectedTab.id, revealSelection: revealSelection, colors: Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in tab.color.map { (tab.id, $0) } }))
    }
    func refreshAppearance() {
        window?.backgroundColor = TerminalTheme.windowBackground
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidate)
        }
        tabs.forEach { invalidate($0.root.view) }
        invalidate(tabStrip)
    }
    func windowDidResize(_ notification: Notification) {
        layoutTabStrip()
        tabStrip.revealSelection()
    }
    func windowDidResignKey(_ notification: Notification) { selectedTab.updateModifiers([]) }
    func windowDidBecomeKey(_ notification: Notification) { selectedTab.updateModifiers(NSEvent.modifierFlags) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onQuitRequested(); return false }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectTabPlacement(_:)):
            item.state = (item.representedObject as? String) == tabPlacement.rawValue ? .on : .off
            return true
        case #selector(newTab(_:)), #selector(closeTab(_:)), #selector(renameTab(_:)):
            return canChangeTab
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return tabs.count > 1 && canChangeTab
        default: return true
        }
    }

    @objc func matchDirectory(_ sender: Any?) { selectedTab.matchDirectory(sender) }
    @objc func leftLocations(_ sender: Any?) { selectedTab.leftLocations(sender) }
    @objc func rightLocations(_ sender: Any?) { selectedTab.rightLocations(sender) }
    @objc func refresh(_ sender: Any?) { selectedTab.refresh(sender) }
    @objc func goHome(_ sender: Any?) { selectedTab.goHome(sender) }
    @objc func toggleHidden(_ sender: Any?) { selectedTab.toggleHidden(sender) }
    @objc func goToFolder(_ sender: Any?) { selectedTab.goToFolder(sender) }
}
