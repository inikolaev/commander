import AppKit
import Foundation
import Testing
import FileManagerCore
import ArchiveTestSupport
@testable import CommanderUI

@MainActor private func settleArchivePanes(_ panes: [PaneViewController]) async throws {
    for _ in 0..<400 {
        if panes.allSatisfy({ !$0.isLoading }) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Archive navigation did not finish")
}

@Test @MainActor func enterArchiveMatchPaneAndExitRestoresSelection() async throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    let tab = controller.selectedTab
    defer { tab.closeTerminal(); window.orderOut(nil) }
    let panes = tab.root.children.compactMap { $0 as? PaneViewController }
    let archive = ArchiveFixtures.url("tree.zip")
    let host = archive.deletingLastPathComponent()
    panes[0].load(host, preferredSelection: archive)
    panes[1].load(host)
    try await settleArchivePanes(panes)
    panes[0].onAction?(.open)
    try await settleArchivePanes(panes)
    #expect(panes[0].state.directory.scheme == "archive")
    #expect(panes[0].state.parent == host)
    #expect(panes[1].state.directory.isFileURL)
    #expect(tab.toggleTerminal())
    let terminal = try #require(tab.terminal)
    let mailbox = try Data(contentsOf: terminal.mailbox.directory.appendingPathComponent("directory"))
    #expect(mailbox.suffix(host.path.utf8.count + 1) == Data((host.path + "\0").utf8))
    terminal.handleShellEvent("prompt 0")
    #expect(tab.toggleTerminal())
    try await settleArchivePanes(panes)
    tab.matchDirectory(nil)
    try await settleArchivePanes(panes)
    #expect(panes[0].state.directory == panes[1].state.directory)
    let folder = try #require(panes[0].state.rows.firstIndex { $0.name == "implicit" })
    (panes[0].view as? TerminalPaneView)?.onInput?(.select(folder))
    panes[0].openSelected()
    try await settleArchivePanes(panes)
    #expect(panes[0].state.directory.path == "/implicit")
    #expect(panes[1].state.directory.path == "/")
    panes[0].goToParent()
    try await settleArchivePanes(panes)
    #expect(panes[0].state.selectedRow?.name == "implicit")
    panes[0].goToParent()
    try await settleArchivePanes(panes)
    #expect(panes[0].state.directory == host)
    #expect(panes[0].state.selectedRow?.url == archive)
    #expect(panes[1].state.directory.scheme == "archive")
}

@Test @MainActor func archiveOperationsAreDisabledForBothTransferDirections() async throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    let tab = controller.selectedTab
    defer { tab.closeTerminal(); window.orderOut(nil) }
    let panes = tab.root.children.compactMap { $0 as? PaneViewController }
    let archive = ArchiveFixtures.url("tree.zip")
    let fs = try ArchiveFileSystem(url: archive)
    panes[0].load(session: fs.session)
    panes[1].load(archive.deletingLastPathComponent(), preferredSelection: archive)
    try await settleArchivePanes(panes)
    let file = try #require(panes[0].state.rows.firstIndex { $0.name == "nested.zip" })
    (panes[0].view as? TerminalPaneView)?.onInput?(.select(file))
    let original = panes[0].state.directory
    for action: PaneAction in [.open, .editFile, .createFile, .createDirectory, .copy, .move, .rename, .delete] {
        panes[0].onAction?(action)
        #expect(!tab.fileOperationInProgress)
        #expect(window.attachedSheet == nil)
        #expect(panes[0].state.directory == original)
    }
    let bar = try #require(tab.root.view.subviews.compactMap { $0 as? TerminalKeyBar }.first)
    #expect(bar.labels[3] == "View")
    #expect(bar.labels[5] == nil)
    panes[1].onAction?(.activate)
    #expect(bar.labels[3] == "View")
    #expect(bar.labels[5] == nil)
    for action: PaneAction in [.copy, .move] {
        panes[1].onAction?(action)
        #expect(!tab.fileOperationInProgress)
        #expect(window.attachedSheet == nil)
    }
}

@Test @MainActor func failedArchiveLoadPreservesPaneAndLaterNavigationWins() async throws {
    _ = NSApplication.shared
    let archive = ArchiveFixtures.url("corrupt.zip")
    let pane = PaneViewController(title: "TEST", directory: archive.deletingLastPathComponent(), reader: LocalDirectoryReader())
    pane.load(archive.deletingLastPathComponent(), preferredSelection: archive)
    try await settleArchivePanes([pane])
    let before = pane.state.directory
    pane.openSelected()
    try await settleArchivePanes([pane])
    #expect(pane.state.directory == before)
    #expect(pane.state.selectedRow?.url == archive)
    #expect((pane.view.accessibilityValue() as? String)?.contains("Cannot open") == true)
    let good = ArchiveFixtures.url("tree.zip")
    pane.load(before, preferredSelection: good)
    try await settleArchivePanes([pane])
    pane.openSelected()
    pane.load(URL(fileURLWithPath: "/"))
    try await settleArchivePanes([pane])
    #expect(pane.state.directory.path == "/")
    #expect(pane.state.directory.isFileURL)
}
