import AppKit
import Foundation
import Testing
@testable import CommanderUI

@MainActor
private func settleTabs(_ controller: CommanderWindowController) async throws {
    for _ in 0..<300 {
        let panes = controller.tabs.flatMap { $0.root.children.compactMap { $0 as? PaneViewController } }
        if panes.allSatisfy({ !$0.isLoading }) && controller.selectedTab.canSwitch { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Tab did not finish loading")
}

@Test @MainActor func tabsKeepIndependentPanesAndAutomaticOrCustomNames() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let a = root.appendingPathComponent("a")
    let b = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let file = a.appendingPathComponent("selected.txt")
    try Data("hello".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    defer { window.orderOut(nil) }
    let first = controller.selectedTab
    let panes = first.root.children.compactMap { $0 as? PaneViewController }
    panes[0].load(a, preferredSelection: file)
    panes[1].load(b)
    try await settleTabs(controller)
    panes[0].onAction?(.activate)
    panes[0].focus()
    let terminal = try #require(panes[0].view as? TerminalPaneView)
    terminal.onInput?(.toggleMark)
    let marks = panes[0].state.markedURLs
    #expect(!marks.isEmpty)
    controller.toggleHidden(nil)
    try await settleTabs(controller)
    #expect(first.title == a.path)
    controller.newTab(nil)
    try await settleTabs(controller)
    #expect(controller.tabs.count == 2)
    let second = controller.selectedTab
    let newPanes = second.root.children.compactMap { $0 as? PaneViewController }
    #expect(newPanes[0] !== panes[0])
    #expect(newPanes[0].state.directory.path == a.path)
    #expect(newPanes[1].state.directory.path == b.path)
    #expect(newPanes[0].state.markedURLs.isEmpty)
    #expect(!newPanes[0].showHidden)
    newPanes[1].onAction?(.activate)
    newPanes[1].focus()
    #expect(second.title == b.path)
    controller.setTabTitle("Research", for: second.id)
    newPanes[1].load(a)
    try await settleTabs(controller)
    #expect(second.title == "Research")
    controller.setTabTitle("  ", for: second.id)
    #expect(second.title == a.path)
    controller.selectTab(id: first.id)
    #expect(window.contentViewController === first.root)
    #expect(window.firstResponder === terminal)
    #expect(panes[0].showHidden)
    #expect(panes[0].state.markedURLs == marks)
    #expect(panes[0].state.selectedRow?.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
    #expect(panes[1].state.directory.path == b.path)
    controller.selectTab(id: second.id)
    #expect(window.firstResponder === newPanes[1].view)
    controller.closeTab(nil)
    #expect(controller.tabs.count == 1)
    #expect(controller.selectedTab === first)
    #expect(window.firstResponder === terminal)
}

@Test @MainActor func tabsPreserveUnsavedEditorAndCancelClosing() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("edit.txt")
    try Data("original".utf8).write(to: file)
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    defer { window.orderOut(nil) }
    let first = controller.selectedTab
    let pane = try #require(first.root.children.first as? PaneViewController)
    pane.load(root, preferredSelection: file)
    try await settleTabs(controller)
    pane.onAction?(.editFile)
    try await settleTabs(controller)
    let editor = try #require(first.root.view.subviews.first { $0 is TerminalFileEditor } as? TerminalFileEditor)
    editor.insertText("changed", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.document.isModified)
    controller.newTab(nil)
    try await settleTabs(controller)
    let second = controller.selectedTab
    #expect(second !== first)
    #expect(editor.window == nil)
    controller.selectTab(id: first.id)
    #expect(window.firstResponder === editor)
    #expect(editor.document.isModified)
    controller.closeTab(nil)
    let dialog = try #require(first.root.view.subviews.first { $0 is TerminalOperationDialog } as? TerminalOperationDialog)
    dialog.onCancel?()
    #expect(controller.tabs.count == 2)
    #expect(window.firstResponder === editor)
    controller.newTab(nil)
    try await settleTabs(controller)
    let third = controller.selectedTab
    controller.closeOtherTabs(id: second.id)
    let bulkDialog = try #require(first.root.view.subviews.first { $0 is TerminalOperationDialog } as? TerminalOperationDialog)
    bulkDialog.onCancel?()
    #expect(controller.tabs.count == 3)
    #expect(controller.selectedTab === first)
    #expect(editor.document.isModified)
    #expect(controller.tabs.contains { $0 === third })
    controller.selectTab(id: third.id)
    controller.closeTab(nil)
    controller.selectTab(id: second.id)
    var quit: Bool?
    controller.prepareForTermination { quit = $0 }
    let quitDialog = try #require(first.root.view.subviews.first { $0 is TerminalOperationDialog } as? TerminalOperationDialog)
    #expect(controller.selectedTab === first)
    quitDialog.onCancel?()
    #expect(quit == false)
    #expect(editor.document.isModified)
    controller.closeTab(nil)
    let discard = try #require(first.root.view.subviews.first { $0 is TerminalOperationDialog } as? TerminalOperationDialog)
    discard.onChoice?(1)
    #expect(controller.tabs.count == 1)
    #expect(controller.selectedTab === second)
    #expect(try String(contentsOf: file, encoding: .utf8) == "original")
}

@Test @MainActor func modalOperationBlocksTabChanges() {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    let first = controller.selectedTab
    controller.isExitPromptVisible = true
    controller.newTab(nil)
    controller.closeTab(nil)
    #expect(controller.tabs.count == 1)
    #expect(controller.selectedTab === first)
    controller.isExitPromptVisible = false
    controller.newTab(nil)
    #expect(controller.tabs.count == 2)
    controller.window?.orderOut(nil)
}

@Test @MainActor func tabPlacementKeepsSessionAndCoexistsWithUpdateAccessory() throws {
    _ = NSApplication.shared
    let prior = UserDefaults.standard.object(forKey: TabPlacement.preferenceKey)
    defer { UserDefaults.standard.set(prior, forKey: TabPlacement.preferenceKey) }
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    defer { window.orderOut(nil) }
    let session = controller.selectedTab
    let update = NSTitlebarAccessoryViewController()
    update.layoutAttribute = .right
    update.view = UpdateAvailableButton(target: nil, action: nil)
    window.addTitlebarAccessoryViewController(update)
    for position in TabPlacement.allCases {
        controller.setTabPlacement(position)
        #expect(controller.selectedTab === session)
        #expect(window.contentViewController === session.root)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(window.titleVisibility == .visible)
        let singleTabFrame = window.frame
        let singleTabContentHeight = window.contentLayoutRect.height
        controller.newTab(nil)
        controller.selectTab(id: session.id)
        #expect(window.frame == singleTabFrame)
        #expect(window.titlebarAccessoryViewControllers.count == 2)
        if position == .belowTitlebar {
            #expect(window.contentLayoutRect.height < singleTabContentHeight)
        }
        let accessory = try #require(window.titlebarAccessoryViewControllers.first { $0 !== update })
        #expect(accessory.layoutAttribute == (position == .titlebar ? .right : .bottom))
        let strip = try #require(accessory.view as? CommanderTabStrip)
        for width: CGFloat in [700, 1080, 1500] {
            window.setContentSize(NSSize(width: width, height: 600))
            controller.layoutTabStrip()
            #expect(strip.frame.width <= window.frame.width)
            if position == .titlebar {
                #expect(strip.frame.width + update.view.frame.width + 100 <= window.frame.width + 1)
            }
        }
        let frame = window.frame
        controller.newTab(nil)
        #expect(window.frame == frame)
        controller.selectTab(id: session.id)
        #expect(window.frame == frame)
        let item = NSMenuItem(title: "", action: #selector(CommanderWindowController.selectTabPlacement(_:)), keyEquivalent: "")
        item.representedObject = position.rawValue
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .on)
        let multipleTabFrame = window.frame
        while controller.tabs.count > 1 {
            if controller.selectedTab === session { controller.nextTab(nil) }
            controller.closeTab(nil)
        }
        #expect(window.frame == multipleTabFrame)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(window.titlebarAccessoryViewControllers.first === update)
        #expect(window.titleVisibility == .visible)
    }
}

@Test @MainActor func overflowingTabsScrollAndRevealSelection() throws {
    _ = NSApplication.shared
    let strip = CommanderTabStrip()
    strip.setFrameSize(NSSize(width: 350, height: 36))
    let tabs = (0..<20).map { (UUID(), "/Users/test/Projects/folder-\($0)") }
    strip.update(tabs: tabs, selected: tabs[0].0, revealSelection: true)
    #expect(strip.scrollView.contentView.bounds.minX == 0)
    strip.scrollView.scrollHorizontally(by: 160)
    #expect(strip.scrollView.contentView.bounds.minX > 0)
    strip.update(tabs: tabs, selected: tabs[19].0, revealSelection: true)
    #expect(strip.scrollView.contentView.bounds.minX > 160)
    strip.scrollView.scrollHorizontally(by: -100_000)
    #expect(strip.scrollView.contentView.bounds.minX == 0)
    strip.scrollView.scrollHorizontally(by: 100_000)
    let maxX = try #require(strip.scrollView.documentView).frame.width - strip.scrollView.contentView.bounds.width
    #expect(abs(strip.scrollView.contentView.bounds.minX - maxX) < 1)
}

@Test @MainActor func tabsPreserveViewerAndRestoreContentFocusAfterTabButtonFocus() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("view.txt")
    try Data("A viewer in one tab".utf8).write(to: file)
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    defer { window.orderOut(nil) }
    let first = controller.selectedTab
    let pane = try #require(first.root.children.first as? PaneViewController)
    pane.load(root, preferredSelection: file)
    try await settleTabs(controller)
    pane.onAction?(.viewFile)
    try await settleTabs(controller)
    let viewer = try #require(first.root.view.subviews.first { $0 is TerminalFileViewer } as? TerminalFileViewer)
    // Full keyboard access can focus a title-bar control before its action runs.
    window.makeFirstResponder(window)
    controller.newTab(nil)
    try await settleTabs(controller)
    #expect(viewer.window == nil)
    controller.selectTab(id: first.id)
    #expect(window.firstResponder === viewer)
    #expect(first.root.view.subviews.contains { $0 === viewer })
    controller.closeTab(nil)
    #expect(controller.tabs.count == 1)
    #expect(!controller.selectedTab.root.view.subviews.contains { $0 is TerminalFileViewer })
}

@Test @MainActor func tabMenuBulkActionsUseContextTabAndKeepItsColor() {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    defer { controller.window?.orderOut(nil) }
    let first = controller.selectedTab
    controller.newTab(nil)
    let second = controller.selectedTab
    controller.newTab(nil)
    controller.newTab(nil)
    controller.setTabColor(.orange, for: second.id)
    controller.setTabTitle("Keep this tab", for: second.id)
    #expect(second.color == .orange)
    #expect(first.color == nil)
    controller.closeTabsToRight(id: second.id)
    #expect(controller.tabs.map(\.id) == [first.id, second.id])
    #expect(controller.selectedTab === second)
    #expect(second.color == .orange)
    controller.closeTabsToRight(id: second.id) // Last tab: no-op.
    #expect(controller.tabs.count == 2)
    controller.selectTab(id: first.id)
    controller.closeOtherTabs(id: second.id)
    #expect(controller.tabs.count == 1)
    #expect(controller.selectedTab === second)
    #expect(second.title == "Keep this tab")
    #expect(second.color == .orange)
    controller.setTabColor(nil, for: second.id)
    #expect(second.color == nil)
    controller.closeOtherTabs(id: second.id) // Never closes the last tab.
    #expect(controller.tabs.count == 1)
}
