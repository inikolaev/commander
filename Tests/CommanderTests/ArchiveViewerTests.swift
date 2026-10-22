import AppKit
import Foundation
import Testing
import FileManagerCore
import ArchiveTestSupport
@testable import Commander

@Test @MainActor func f3ViewsArchiveJSONAndEscapeRestoresPaneSelection() async throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    let tab = controller.selectedTab
    defer { tab.closeViewer(); tab.closeTerminal(); window.orderOut(nil) }
    let pane = try #require(tab.root.children.first as? PaneViewController)
    let fs = try ArchiveFileSystem(url: ArchiveFixtures.url("viewer.zip"))
    let path = fs.root.url.appendingPathComponent("config.json")
    pane.load(session: fs.session, preferredSelection: path)
    for _ in 0..<200 {
        if !pane.isLoading { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    pane.focus()
    pane.onAction?(.viewFile)
    for _ in 0..<200 {
        if tab.root.view.subviews.contains(where: { $0 is TerminalFileViewer }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(tab.root.view.subviews.compactMap { $0 as? TerminalFileViewer }.first)
    #expect(viewer.page?.lines.first?.text == "{\"message\":\"hello\",\"enabled\":true}")
    #expect(viewer.syntaxHighlightingEnabled)
    #expect(viewer.path.hasSuffix("viewer.zip!/config.json"))
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
    viewer.keyDown(with: escape)
    #expect(window.firstResponder === pane.view)
    #expect(pane.state.selectedRow?.url == path)
    #expect(pane.state.directory == fs.root.url)
}

private actor PendingOpen: FileContentSource {
    var cancelled = false
    func open(delayOpen: Bool) async throws -> any FileContentSource {
        if !delayOpen { return self }
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        throw CocoaError(.fileReadUnknown)
    }
    func metadata() -> ContentMetadata { ContentMetadata(size: 5) }
    func length() -> Int64 { 5 }
    func read(at offset: Int64, count: Int) async throws -> Data {
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
        return Data("hello".utf8)
    }
}

@Test(arguments: [true, false]) @MainActor func escapeCancelsBeforeFirstViewerPageAppears(delayOpen: Bool) async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileViewerCoordinator()
    let pending = PendingOpen()
    coordinator.present(url: URL(string: "archive://test/large.txt")!, displayPath: "test.zip!/large.txt", window: window) {
        try await pending.open(delayOpen: delayOpen)
    }
    for _ in 0..<200 {
        if pane.subviews.contains(where: { $0 is TerminalOperationDialog }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let dialog = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
    dialog.keyDown(with: escape)
    for _ in 0..<200 {
        if await pending.cancelled { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await pending.cancelled)
    #expect(coordinator.view == nil)
    #expect(pane.subviews.isEmpty)
    #expect(window.firstResponder === pane)
}

@Test func archiveViewCapabilityRejectsLinksAndForeignPaths() throws {
    let fs = try ArchiveFileSystem(url: ArchiveFixtures.url("tree.tar"))
    #expect(!fs.canViewFile(at: fs.root))
    #expect(!fs.canViewFile(at: FileSystemPath(fs.root.url.appendingPathComponent("link"))))
    #expect(fs.canViewFile(at: FileSystemPath(fs.root.url.appendingPathComponent("implicit/deep/hello.txt"))))
    #expect(!fs.canViewFile(at: FileSystemPath(URL(string: "archive://other/implicit/deep/hello.txt")!)))
}
