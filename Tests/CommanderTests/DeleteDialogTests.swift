import AppKit
import Foundation
import Testing
import FileManagerCore
@testable import Commander

private final class RecordingTrasher: FileTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    let shouldFail: Bool
    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
    var recorded: [URL] { lock.withLock { items } }
    func trashItem(at url: URL) throws {
        lock.withLock { items.append(url) }
        if shouldFail { throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
    }
}

@MainActor private func deleteWindow() -> (NSWindow, TerminalPaneView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    return (window, pane)
}

@Test @MainActor func deleteConfirmationDefaultsToCancelAndDoesNotTrash() throws {
    let (window, pane) = deleteWindow()
    let trasher = RecordingTrasher()
    let coordinator = DeleteCoordinator(trasher: trasher)
    coordinator.begin(item: URL(fileURLWithPath: "/example.txt"), isDirectory: false,
        window: window, onStart: {}, onFinish: { _ in Issue.record("Cancelled deletion must not run") })
    let dialog = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    #expect(dialog.focusedControl == 1)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    dialog.keyDown(with: enter)
    #expect(trasher.recorded.isEmpty)
    #expect(!coordinator.isBusy)
    #expect(window.firstResponder === pane)
}

@Test @MainActor func confirmedDeleteUsesSelectedItemAndRestoresFocus() async throws {
    let (window, pane) = deleteWindow()
    let trasher = RecordingTrasher()
    let coordinator = DeleteCoordinator(trasher: trasher)
    let selected = URL(fileURLWithPath: "/selected folder")
    var completed = false
    coordinator.begin(item: selected, isDirectory: true, window: window, onStart: {}, onFinish: { result in
        if case .success = result { completed = true }
    })
    let dialog = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    dialog.onConfirm?("")
    for _ in 0..<100 {
        if completed { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(completed)
    #expect(trasher.recorded == [selected])
    #expect(!coordinator.isBusy)
    #expect(pane.subviews.isEmpty)
    #expect(window.firstResponder === pane)
}

@Test @MainActor func deletionErrorStaysModalUntilAcknowledged() async throws {
    let (window, pane) = deleteWindow()
    let coordinator = DeleteCoordinator(trasher: RecordingTrasher(shouldFail: true))
    var completed = false
    coordinator.begin(item: URL(fileURLWithPath: "/example.txt"), isDirectory: false,
        window: window, onStart: {}, onFinish: { _ in completed = true })
    let dialog = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    dialog.onConfirm?("")
    var errorDialog: TerminalOperationDialog?
    for _ in 0..<100 {
        if let candidate = pane.subviews.compactMap({ $0 as? TerminalOperationDialog }).first,
           case .error(_, let title) = candidate.mode {
            #expect(title == "Delete error")
            errorDialog = candidate
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    let error = try #require(errorDialog)
    #expect(coordinator.isBusy)
    #expect(!completed)
    error.onDismiss?()
    #expect(completed)
    #expect(!coordinator.isBusy)
    #expect(window.firstResponder === pane)
}

@Test @MainActor func batchDeleteConfirmsAllMarkedItemsAndDefaultsToCancel() async throws {
    let (window, pane) = deleteWindow()
    let trasher = RecordingTrasher()
    let coordinator = DeleteCoordinator(trasher: trasher)
    let items = [URL(fileURLWithPath: "/one.txt"), URL(fileURLWithPath: "/folder")]
    var completed: [URL] = []
    coordinator.begin(items: items, includesDirectories: true, window: window, onStart: {}, onFinish: { result in
        if case .success(let urls) = result { completed = urls }
    })
    let confirmation = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    #expect(confirmation.focusedControl == 1)
    #expect(trasher.recorded.isEmpty)
    confirmation.onConfirm?("")
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(completed == items)
    #expect(trasher.recorded == items)
    #expect(window.firstResponder === pane)
}
