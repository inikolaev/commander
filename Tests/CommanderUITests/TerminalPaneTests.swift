import AppKit
import Foundation
import Testing
import FileManagerCore
@testable import CommanderUI

@Test @MainActor func customPaneHandlesKeyboardAndRendersLongUnicodeNames() throws {
    _ = NSApplication.shared
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    for name in ["Applications", "Documents", "Downloads"] {
        try manager.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false)
    }
    for index in 1...65 {
        try Data().write(to: directory.appendingPathComponent(String(format: "file-%02d.txt", index)))
    }
    try Data().write(to: directory.appendingPathComponent("日本語 — a very long filename with emoji 📁.txt"))
    var state = PaneState(directory: directory)
    let entries = try LocalDirectoryReader().entries(at: directory, showHidden: false)
    state.replace(directory: directory, entries: entries)
    let view = TerminalPaneView(name: "Test pane")
    view.frame = NSRect(x: 0, y: 0, width: 540, height: 640)
    view.isActive = true
    var switched = false
    var copied = false
    var deleted = false
    var viewed = false
    var quit = false
    view.onInput = { input in
        switch input {
        case .select(let index):
            state.select(index)
            view.update(state: state, status: "\(entries.count) items")
        case .switchPane: switched = true
        case .copy: copied = true
        case .delete: deleted = true
        case .viewFile: viewed = true
        case .quit: quit = true
        default: break
        }
    }
    defer { view.onInput = nil }
    view.update(state: state, status: "\(entries.count) items")
    func press(_ key: NSEvent.SpecialKey) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
            characters: String(key.unicodeScalar), charactersIgnoringModifiers: String(key.unicodeScalar), isARepeat: false, keyCode: 0))
        view.keyDown(with: event)
    }
    try press(.rightArrow) // Right: next name column, not folder entry.
    #expect(state.selectedIndex == view.geometry.rowsPerColumn)
    try press(.end) // End.
    #expect(state.selectedIndex == state.rows.count - 1)
    #expect(view.viewport.firstIndex > 0)
    view.setFrameSize(NSSize(width: 350, height: 380))
    let selection = try #require(state.selectedIndex)
    #expect((view.viewport.firstIndex..<view.viewport.firstIndex + view.viewport.capacity).contains(selection))
    try press(.home) // Home.
    #expect(state.selectedIndex == 0)
    #expect(view.viewport.firstIndex == 0)
    try press(.tab)
    #expect(switched)
    try press(.f5) // F5 dispatches the same action as the footer button.
    #expect(copied)
    try press(.f8)
    #expect(deleted)
    try press(.f3)
    #expect(viewed)
    try press(.f10)
    #expect(quit)

    // Optional render artifact comes from this test view, not from screen capture.
    if let output = ProcessInfo.processInfo.environment["COMMANDER_RENDER_PATH"] {
        view.setFrameSize(NSSize(width: 540, height: 640))
        state.replace(directory: URL(fileURLWithPath: "/Users/demo"), entries: entries)
        view.update(state: state, status: "\(entries.count) items")
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
    }
}

@Test @MainActor func spaceTogglesYellowMarksWithoutMovingCursor() throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: "/example")
    var state = PaneState(directory: directory)
    let file = FileEntry(url: directory.appendingPathComponent(".archive.zip"), name: ".archive.zip",
        isDirectory: false, isSymbolicLink: false, size: 1024, modified: nil)
    state.replace(directory: directory, entries: [file])
    state.select(1)
    let view = TerminalPaneView(name: "Selection preview")
    view.frame = NSRect(x: 0, y: 0, width: 540, height: 300)
    view.isActive = true
    view.onInput = { input in
        if case .toggleMark = input {
            state.toggleMark()
            view.update(state: state, status: "1 item")
        }
    }
    defer { view.onInput = nil }
    view.update(state: state, status: "1 item")
    let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    view.keyDown(with: space)
    #expect(state.markedURLs == [file.url])
    #expect(state.selectedIndex == 1)
    for active in [true, false] {
        #expect(FileColorScheme.color(for: .entry(file), isSelected: active, isMarked: true) == TerminalTheme.markedFile)
    }
    if let output = ProcessInfo.processInfo.environment["COMMANDER_SELECTION_RENDER_PATH"] {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
    view.keyDown(with: space)
    #expect(state.markedURLs.isEmpty)
}

@Test @MainActor func paneSpecialKeysPreserveTabEnterAndBackspaceActions() throws {
    _ = NSApplication.shared
    let view = TerminalPaneView(name: "Test")
    var actions: [PaneInput] = []
    view.onInput = { actions.append($0) }
    for key: NSEvent.SpecialKey in [.tab, .backTab, .carriageReturn, .enter, .delete, .backspace] {
        let text = String(key.unicodeScalar)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: key == .backTab ? .shift : [], timestamp: 1, windowNumber: 0,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        view.keyDown(with: event)
    }
    #expect(actions.count == 6)
    guard actions.count == 6 else { return }
    for action in actions[0..<2] {
        if case .switchPane = action {} else { Issue.record("Expected pane switch") }
    }
    for action in actions[2..<4] {
        if case .open = action {} else { Issue.record("Expected open") }
    }
    for action in actions[4..<6] {
        if case .parent = action {} else { Issue.record("Expected parent directory") }
    }
}
