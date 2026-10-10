import AppKit
import Testing
import FileManagerCore
@testable import CommanderUI

@Test @MainActor func renameDialogRetriesAndRenamesFile() async throws {
    _ = NSApplication.shared
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let source = parent.appendingPathComponent("original.txt")
    try Data("test".utf8).write(to: source)
    let coordinator = RenameCoordinator()
    var created: URL?
    coordinator.begin(source: source, window: window) { created = $0 }
    func dialog() throws -> TerminalOperationDialog {
        try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    }
    let initial = try dialog()
    let field = try #require(initial.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(field.stringValue == "original.txt")
    #expect(field.currentEditor() != nil)
    if let output = ProcessInfo.processInfo.environment["COMMANDER_RENAME_RENDER_PATH"] {
        let bitmap = try #require(initial.bitmapImageRepForCachingDisplay(in: initial.bounds))
        initial.cacheDisplay(in: initial.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
    initial.onConfirm?("../bad")
    for _ in 0..<200 {
        if case .error = try dialog().mode { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let error = try dialog()
    guard case .error = error.mode else { Issue.record("Expected error"); return }
    error.onDismiss?()
    let retry = try dialog()
    #expect(retry.subviews.compactMap { $0 as? NSTextField }.first?.stringValue == "../bad")
    retry.onConfirm?("renamed.txt")
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(created?.lastPathComponent == "renamed.txt")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(window.firstResponder === pane)
    #expect(pane.subviews.isEmpty)
    coordinator.begin(source: source, window: window) { _ in Issue.record("Cancel must not rename") }
    try dialog().onCancel?()
    #expect(!coordinator.isBusy)
    #expect(window.firstResponder === pane)
}


@Test @MainActor func shiftFunctionKeysRouteSupportedActions() throws {
    _ = NSApplication.shared
    let view = TerminalPaneView(name: "Test")
    var actions: [PaneInput] = []
    view.onInput = { actions.append($0) }
    for key: NSEvent.SpecialKey in [.f3, .f4, .f5, .f6, .f7, .f8, .f10] {
        view.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: String(key.unicodeScalar), charactersIgnoringModifiers: String(key.unicodeScalar), isARepeat: false, keyCode: 0)))
    }
    #expect(actions.count == 2)
    if case .createFile = actions.first {} else { Issue.record("Expected create file") }
    if case .rename = actions.last {} else { Issue.record("Expected rename") }
    let bar = TerminalKeyBar()
    #expect(bar.labels[6] == "Move")
    bar.shiftPressed = true
    #expect(bar.labels == [4: "New file", 6: "Rename"])
    #expect(TerminalKeyBar.command(number: 5, shift: true) == nil)
    #expect(TerminalKeyBar.command(number: 6, shift: true) == .rename)
    bar.shiftPressed = false
    #expect(bar.labels[3] == "View")
}
