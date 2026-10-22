import AppKit
import Testing
@testable import Commander

@Test @MainActor func exitConfirmationDefaultsToCancelAndHandlesQuit() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = ExitCoordinator()
    var replies: [Bool] = []
    coordinator.request(window: window, operationInProgress: false) { replies.append($0) }
    coordinator.request(window: window, operationInProgress: false) { _ in Issue.record("Duplicate prompt") }
    #expect(pane.subviews.count == 1)
    let dialog = try #require(pane.subviews.first as? TerminalOperationDialog)
    #expect(dialog.focusedControl == 1)
    if let path = ProcessInfo.processInfo.environment["COMMANDER_EXIT_RENDER_PATH"] {
        let bitmap = try #require(dialog.bitmapImageRepForCachingDisplay(in: dialog.bounds))
        dialog.cacheDisplay(in: dialog.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    dialog.keyDown(with: try key(36)) // Enter defaults to Cancel.
    #expect(replies == [false])
    #expect(window.firstResponder === pane)
    coordinator.request(window: window, operationInProgress: false) { replies.append($0) }
    let quit = try #require(pane.subviews.first as? TerminalOperationDialog)
    quit.keyDown(with: try key(48)) // Tab to Quit.
    quit.keyDown(with: try key(36))
    #expect(replies == [false, true])
    #expect(!coordinator.isPresented)
}

@Test(arguments: [true, false]) @MainActor func exitDuringFileOperationDoesNotConfirmTermination(requiresConfirmation: Bool) throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let coordinator = ExitCoordinator()
    var answer: Bool?
    coordinator.request(window: window, operationInProgress: true, requiresConfirmation: requiresConfirmation) { answer = $0 }
    let dialog = try #require(window.contentView?.subviews.first as? TerminalOperationDialog)
    guard case .error = dialog.mode else { Issue.record("Expected busy explanation"); return }
    dialog.onDismiss?()
    #expect(answer == false)
}

@Test @MainActor func updateRestartSkipsExitConfirmationAndDefersReply() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = ExitCoordinator()
    // A retry after cancelling an unsaved-document prompt also skips confirmation.
    for _ in 0..<2 {
        var reply: Bool?
        await withCheckedContinuation { continuation in
            coordinator.request(window: window, operationInProgress: false, requiresConfirmation: false) {
                reply = $0
                continuation.resume()
            }
            #expect(reply == nil)
            #expect(pane.subviews.isEmpty)
            #expect(window.firstResponder === pane)
        }
        #expect(reply == true)
        #expect(!coordinator.isPresented)
    }
    // A normal quit still requires confirmation after the update flow ends.
    var normalReply: Bool?
    coordinator.request(window: window, operationInProgress: false) { normalReply = $0 }
    let dialog = try #require(pane.subviews.first as? TerminalOperationDialog)
    #expect(normalReply == nil)
    #expect(dialog.focusedControl == 1)
    dialog.onCancel?()
    #expect(normalReply == false)
}

@Test @MainActor func closingWindowRequestsQuitWithoutClosingImmediately() throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    var requests = 0
    controller.onQuitRequested = { requests += 1 }
    let window = try #require(controller.window)
    #expect(window.delegate === controller)
    #expect(!controller.windowShouldClose(window))
    #expect(requests == 1)
}
