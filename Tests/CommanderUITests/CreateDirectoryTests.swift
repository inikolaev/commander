import AppKit
import Testing
import FileManagerCore
@testable import CommanderUI

@Test @MainActor func createDirectoryDialogRetriesAndCreatesFolder() async throws {
    _ = NSApplication.shared
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = CreateDirectoryCoordinator()
    var created: URL?
    coordinator.begin(directory: parent, window: window) { created = $0 }
    func dialog() throws -> TerminalOperationDialog {
        try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    }
    let initial = try dialog()
    let field = try #require(initial.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(field.stringValue.isEmpty)
    #expect(field.currentEditor() != nil)
    if let output = ProcessInfo.processInfo.environment["COMMANDER_MKDIR_RENDER_PATH"] {
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
    retry.onConfirm?("New folder")
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(created?.lastPathComponent == "New folder")
    #expect(window.firstResponder === pane)
    #expect(pane.subviews.isEmpty)
    coordinator.begin(directory: parent, window: window) { _ in Issue.record("Cancel must not create") }
    try dialog().onCancel?()
    #expect(!coordinator.isBusy)
    #expect(window.firstResponder === pane)
}

@Test @MainActor func f7RoutesDirectoryCreation() throws {
    _ = NSApplication.shared
    let view = TerminalPaneView(name: "Test")
    var invoked = false
    view.onInput = { if case .createDirectory = $0 { invoked = true } }
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: String(NSEvent.SpecialKey.f7.unicodeScalar),
            charactersIgnoringModifiers: String(NSEvent.SpecialKey.f7.unicodeScalar), isARepeat: false, keyCode: 0))
    view.keyDown(with: key)
    #expect(invoked)
    #expect(TerminalKeyBar.Command(rawValue: 7) == .createDirectory)
}
