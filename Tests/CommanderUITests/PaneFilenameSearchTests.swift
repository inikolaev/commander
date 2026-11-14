import AppKit
import FileManagerCore
import Foundation
import Testing
@testable import CommanderUI

private struct DelayedDirectoryReader: DirectoryReading {
    func entries(at directory: URL, showHidden: Bool) throws -> [FileEntry] {
        Thread.sleep(forTimeInterval: 0.15)
        return try LocalDirectoryReader().entries(at: directory, showHidden: showHidden)
    }
}

@Test @MainActor func optionFilenameSearchUsesActivePaneAndSurvivesRefresh() async throws {
    _ = NSApplication.shared
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let leftDirectory = root.appendingPathComponent("left")
    let rightDirectory = root.appendingPathComponent("right")
    for directory in [leftDirectory, rightDirectory] {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? manager.removeItem(at: root) }
    for name in ["Alpha.txt", "apple.txt", "zeta.txt"] {
        try Data().write(to: leftDirectory.appendingPathComponent(name))
    }
    for index in 0..<80 {
        try Data().write(to: leftDirectory.appendingPathComponent(String(format: "file-%02d.txt", index)))
    }
    try Data().write(to: rightDirectory.appendingPathComponent("Alpha right.txt"))
    let window = CommanderWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let tab = CommanderTabSession(window: window, directories: [leftDirectory, rightDirectory], locationReader: LocalLocationReader())
    window.contentViewController = tab.root
    window.onTerminalInput = { tab.routeTerminalInput($0) }
    tab.start()
    defer { tab.closeTerminal(); window.onTerminalInput = nil; window.orderOut(nil) }
    let panes = tab.root.children.compactMap { $0 as? PaneViewController }
    for _ in 0..<200 where panes.contains(where: \.isLoading) {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(panes.allSatisfy { !$0.isLoading })
    let left = try #require(panes[0].view as? TerminalPaneView)
    let alpha = try #require(panes[0].state.rows.firstIndex { $0.name == "Alpha.txt" })
    let zeta = try #require(panes[0].state.rows.firstIndex { $0.name == "zeta.txt" })
    left.onInput?(.select(alpha))
    left.onInput?(.toggleMark)
    let marks = panes[0].state.markedURLs
    left.onInput?(.select(zeta))
    let rightSelection = panes[1].state.selectedIndex
    window.makeFirstResponder(left)

    func key(_ characters: String, ignoring: String, flags: NSEvent.ModifierFlags, code: UInt16 = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code))
    }
    // A macOS Option+A event can produce å; the search must start with the filename key, a.
    window.sendEvent(try key("å", ignoring: "a", flags: .option))
    let surface = try #require(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.first)
    #expect(surface.query == "a")
    #expect(window.firstResponder is NSTextView)
    #expect(panes[0].state.selectedRow?.name == "Alpha.txt")
    #expect(panes[0].state.markedURLs == marks)
    #expect(panes[1].state.selectedIndex == rightSelection)
    #expect(!surface.change(to: "axxxxxxxxx"))
    #expect(surface.query == "a")
    window.sendEvent(try key("l", ignoring: "l", flags: []))
    #expect(surface.query == "al")
    #expect(surface.change(to: "a"))

    let editor = try #require(window.firstResponder as? NSTextView)
    editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    #expect(!tab.routeTerminalInput(try key("\r", ignoring: "\r", flags: [], code: 36)))
    #expect(!tab.routeTerminalInput(try key("\u{1B}", ignoring: "\u{1B}", flags: [], code: 53)))
    #expect(surface.superview != nil)
    editor.unmarkText()
    #expect(surface.change(to: "a"))

    #expect(tab.routeTerminalInput(try key("\r", ignoring: "\r", flags: .control, code: 36)))
    #expect(panes[0].state.selectedRow?.name == "apple.txt")
    #expect(tab.routeTerminalInput(try key("\r", ignoring: "\r", flags: [.control, .shift], code: 36)))
    #expect(panes[0].state.selectedRow?.name == "Alpha.txt")
    let distantIndex = try #require(panes[0].state.rows.firstIndex { $0.name == "zeta.txt" })
    #expect(distantIndex >= left.viewport.firstIndex + left.viewport.capacity)
    #expect(surface.change(to: "z"))
    #expect(panes[0].state.selectedRow?.name == "zeta.txt")
    let zetaIndex = try #require(panes[0].state.selectedIndex)
    #expect((left.viewport.firstIndex..<left.viewport.firstIndex + left.viewport.rowsPerColumn).contains(zetaIndex))
    #expect(surface.change(to: "a"))

    try Data().write(to: leftDirectory.appendingPathComponent("after.txt"))
    panes[0].refresh()
    for _ in 0..<200 where !panes[0].state.rows.contains(where: { $0.name == "after.txt" }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(panes[0].state.rows.contains { $0.name == "after.txt" })
    #expect(surface.superview != nil)
    #expect(surface.query == "a")

    let beforeArrow = try #require(panes[0].state.selectedIndex)
    window.sendEvent(try key(String(NSEvent.SpecialKey.downArrow.unicodeScalar),
        ignoring: String(NSEvent.SpecialKey.downArrow.unicodeScalar), flags: [], code: 125))
    #expect(surface.superview == nil)
    #expect(panes[0].state.selectedIndex == min(beforeArrow + 1, panes[0].state.rows.count - 1))
    #expect(tab.routeTerminalInput(try key("å", ignoring: "a", flags: .option)))
    let secondSurface = try #require(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.first)
    window.makeFirstResponder(left)
    #expect(secondSurface.superview == nil)
    #expect(panes[0].state.markedURLs == marks)
    let compactTerminal = try #require(tab.terminal)
    window.makeFirstResponder(compactTerminal.view)
    #expect(!tab.routeTerminalInput(try key("å", ignoring: "a", flags: .option)))
    #expect(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.isEmpty)
    window.makeFirstResponder(left)
    _ = tab.routeTerminalInput(try key("/", ignoring: "/", flags: .option))
    #expect(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.isEmpty)
    window.makeFirstResponder(left)
    #expect(tab.routeTerminalInput(try key("å", ignoring: "a", flags: .option)))
    #expect(tab.toggleTerminal())
    #expect(tab.isTerminalVisible)
    #expect(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.isEmpty)
}

@Test @MainActor func filenameSearchStartsDuringLoadAndReturnOpensDirectory() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let child = root.appendingPathComponent("Archive")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let window = CommanderWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let tab = CommanderTabSession(window: window, directories: [root, root],
        locationReader: LocalLocationReader(), reader: DelayedDirectoryReader())
    window.contentViewController = tab.root
    window.onTerminalInput = { tab.routeTerminalInput($0) }
    tab.start()
    defer { tab.closeTerminal(); window.onTerminalInput = nil; window.orderOut(nil) }
    let pane = try #require(tab.root.children.first as? PaneViewController)
    #expect(pane.isLoading)
    let optionA = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
        timestamp: 1, windowNumber: window.windowNumber, context: nil,
        characters: "å", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    window.sendEvent(optionA)
    let surface = try #require(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.first)
    #expect(surface.query == "a")
    for _ in 0..<100 where pane.isLoading {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(pane.state.selectedRow?.name == "Archive")
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    window.sendEvent(enter)
    #expect(surface.superview == nil)
    for _ in 0..<100 where pane.state.directory.path != child.path {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(pane.state.directory.path == child.path)
}

@Test @MainActor func pendingFilenameSearchHandlesNoMatchAndFailedLoad() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let window = CommanderWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let tab = CommanderTabSession(window: window, directories: [root, root],
        locationReader: LocalLocationReader(), reader: DelayedDirectoryReader())
    window.contentViewController = tab.root
    window.onTerminalInput = { tab.routeTerminalInput($0) }
    tab.start()
    defer { tab.closeTerminal(); window.onTerminalInput = nil; window.orderOut(nil) }
    let pane = try #require(tab.root.children.first as? PaneViewController)
    func optionZ() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "Ω", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
    }
    #expect(pane.isLoading)
    window.sendEvent(try optionZ())
    let surface = try #require(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.first)
    #expect(surface.query == "z")
    for _ in 0..<100 where pane.isLoading {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(surface.query.isEmpty)
    #expect(!surface.append("z"))
    window.makeFirstResponder(pane.view)
    #expect(surface.superview == nil)

    pane.load(root.appendingPathComponent("missing"))
    #expect(pane.isLoading)
    window.sendEvent(try optionZ())
    let failedSurface = try #require(tab.root.view.subviews.compactMap { $0 as? PaneFilenameSearchView }.first)
    for _ in 0..<100 where pane.isLoading {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(failedSurface.superview == nil)
    #expect(pane.state.directory.path == root.path)
}
