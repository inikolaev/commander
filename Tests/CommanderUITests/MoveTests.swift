import AppKit
import Testing
import FileManagerCore
@testable import CommanderUI

@Test @MainActor func batchMoveStopsOnCollisionAndReportsCompletedMoves() async throws {
    _ = NSApplication.shared
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("destination")
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let sources = ["one", "two", "three"].map { root.appendingPathComponent($0) }
    for source in sources { try Data("original".utf8).write(to: source) }
    try Data("existing".utf8).write(to: destination.appendingPathComponent("two"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = MoveCoordinator()
    var outcome: MoveCoordinator.Outcome?
    coordinator.begin(sources: sources, directory: destination, window: window) { outcome = $0 }
    func dialog() throws -> TerminalOperationDialog {
        try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    }
    let confirmation = try dialog()
    let field = try #require(confirmation.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(field.stringValue == destination.path)
    confirmation.onConfirm?(field.stringValue)
    for _ in 0..<200 {
        if case .error = try dialog().mode { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let error = try dialog()
    guard case .error = error.mode else { Issue.record("Expected move error"); return }
    error.onDismiss?()
    #expect(outcome?.succeeded == false)
    #expect(outcome?.completed.map(\.source) == [sources[0]])
    #expect(!manager.fileExists(atPath: sources[0].path))
    #expect(manager.fileExists(atPath: sources[1].path))
    #expect(manager.fileExists(atPath: sources[2].path))
    #expect(try String(contentsOf: destination.appendingPathComponent("two"), encoding: .utf8) == "existing")
    #expect(window.firstResponder === pane)
    coordinator.begin(sources: [sources[2]], directory: destination, window: window) { outcome = $0 }
    try dialog().onConfirm?(destination.appendingPathComponent("renamed").path)
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(outcome?.succeeded == true)
    #expect(!manager.fileExists(atPath: sources[2].path))
    #expect(manager.fileExists(atPath: destination.appendingPathComponent("renamed").path))
    coordinator.begin(sources: [sources[1]], directory: destination, window: window) { _ in Issue.record("Cancel must not move") }
    try dialog().onCancel?()
    #expect(!coordinator.isBusy)
    #expect(manager.fileExists(atPath: sources[1].path))
}

@Test @MainActor func f6RoutesMove() throws {
    _ = NSApplication.shared
    let view = TerminalPaneView(name: "Test")
    var invoked = false
    view.onInput = { if case .move = $0 { invoked = true } }
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, characters: String(NSEvent.SpecialKey.f6.unicodeScalar),
            charactersIgnoringModifiers: String(NSEvent.SpecialKey.f6.unicodeScalar), isARepeat: false, keyCode: 0))
    view.keyDown(with: key)
    #expect(invoked)
    #expect(TerminalKeyBar.Command(rawValue: 6) == .move)
}
