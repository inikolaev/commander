import AppKit
import Foundation
import Testing
import FileManagerCore
@testable import Commander

@Test @MainActor func copyDialogKeyboardAndFocus() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    let dialog = TerminalOperationDialog(mode: .confirmation(sourceName: "sample.txt", destination: "/tmp/sample.txt"))
    window.contentView = dialog
    dialog.focusInitialControl()
    let field = try #require(dialog.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(field.stringValue == "/tmp/sample.txt")
    var submitted: String?
    var cancelled = false
    dialog.onConfirm = { submitted = $0 }
    dialog.onCancel = { cancelled = true }
    let editor = NSTextView()
    #expect(dialog.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
    #expect(dialog.focusedControl == 1)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "\r",
        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    dialog.keyDown(with: enter)
    #expect(submitted == "/tmp/sample.txt")
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 53))
    dialog.keyDown(with: escape)
    #expect(cancelled)
}

@Test @MainActor func dialogModesFitSmallWindowAndRender() throws {
    _ = NSApplication.shared
    let modes: [(String, TerminalOperationDialog.Mode)] = [
        ("confirmation", .confirmation(sourceName: "Holiday photo.jpg", destination: "/Users/demo/Backup/Holiday photo.jpg")),
        ("progress", .progress(sourceName: "Holiday photo.jpg", destination: "/Users/demo/Backup/Holiday photo.jpg")),
        ("delete-confirmation", .decision(title: "Delete", message: "Move this file to Trash?\n\nHoliday photo.jpg\n\nYou can recover it from macOS Trash.", confirmTitle: "Trash")),
        ("delete-error", .error(message: "The item could not be moved to Trash because you do not have permission.", title: "Delete error")),
        ("error", .error(message: "An item already exists at the destination. Choose a different name; existing items are not overwritten.")),
    ]
    for (name, mode) in modes {
        let view = TerminalOperationDialog(mode: mode)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 350)
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.contains(view.panelRect))
        view.update(progress: CopyProgress(copiedBytes: 43_000_000, totalBytes: 100_000_000))
        #expect(view.progress.fraction == 0.43)
        if let directory = ProcessInfo.processInfo.environment["COMMANDER_DIALOG_RENDER_DIR"] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("commander-\(name).png"))
        }
    }
}

private struct FailingCopier: FileCopying {
    func copyFile(from source: URL, to destination: URL,
                  progress: @escaping @Sendable (CopyProgress) -> Void,
                  isCancelled: @escaping @Sendable () -> Bool) throws {
        throw FileCopyError.destinationExists
    }
}

@Test @MainActor func copyFailureTransitionsToErrorAndRestoresPaneFocus() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = CopyCoordinator(copier: FailingCopier())
    var finished = false
    coordinator.begin(source: URL(fileURLWithPath: "/source.txt"), directory: URL(fileURLWithPath: "/tmp"),
        window: window, onStart: {}, onFinish: { result in
            if case .failure = result { finished = true }
        })
    #expect(coordinator.isBusy)
    let confirmation = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    confirmation.onConfirm?("/tmp/source.txt")
    var errorDialog: TerminalOperationDialog?
    for _ in 0..<100 {
        if let dialog = pane.subviews.compactMap({ $0 as? TerminalOperationDialog }).first,
           case .error = dialog.mode { errorDialog = dialog; break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let error = try #require(errorDialog)
    #expect(coordinator.isBusy)
    error.onDismiss?()
    #expect(finished)
    #expect(!coordinator.isBusy)
    #expect(pane.subviews.isEmpty)
    #expect(window.firstResponder === pane)
}

@Test @MainActor func batchConfirmationUsesDirectoryAndCopiesBothFiles() async throws {
    _ = NSApplication.shared
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = root.appendingPathComponent("target")
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let sources = ["one", "two"].map { root.appendingPathComponent($0) }
    for source in sources { try Data(source.lastPathComponent.utf8).write(to: source) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let coordinator = CopyCoordinator()
    var succeeded = false
    coordinator.begin(sources: sources, directory: target, window: window, onStart: {}, onFinish: { result in
        if case .success = result { succeeded = true }
    })
    let confirmation = try #require(window.contentView?.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    let field = try #require(confirmation.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(field.stringValue == target.path)
    confirmation.onConfirm?(field.stringValue)
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(succeeded)
    for source in sources { #expect(manager.fileExists(atPath: target.appendingPathComponent(source.lastPathComponent).path)) }
}
