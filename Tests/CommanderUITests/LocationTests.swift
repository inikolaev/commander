import AppKit
import FileManagerCore
import Foundation
import Testing
@testable import CommanderUI

private final class TestLocationReader: LocationReading, @unchecked Sendable {
    private let lock = NSLock()
    private var result: [FileLocation] = []
    func set(_ locations: [FileLocation]) { lock.lock(); defer { lock.unlock() }; result = locations }
    func locations() -> [FileLocation] { lock.lock(); defer { lock.unlock() }; return result }
}

@MainActor
private func waitForLocations(_ window: NSWindow) async throws -> TerminalOperationDialog {
    for _ in 0..<200 {
        if let dialog = window.contentView?.subviews.compactMap({ $0 as? TerminalOperationDialog }).first,
           case .list(_, let message, _) = dialog.mode, message == "Choose a location" { return dialog }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw NSError(domain: "LocationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Location picker did not finish loading"])
}

@Test @MainActor func locationsChooseTargetPaneCancelAndRefreshList() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("drive", isDirectory: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let reader = TestLocationReader()
    reader.set([FileLocation(name: "Test drive", url: destination)])
    let controller = CommanderWindowController(locationReader: reader)
    let window = try #require(controller.window)
    defer { window.orderOut(nil) }
    let panes = try #require(window.contentViewController?.children.compactMap { $0 as? PaneViewController })
    for pane in panes { pane.load(root) }
    func settle() async throws {
        for _ in 0..<200 {
            if panes.allSatisfy({ !$0.isLoading }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Directory load did not finish")
    }
    try await settle()
    panes[0].focus()
    controller.rightLocations(nil)
    let picker = try await waitForLocations(window)
    #expect(controller.fileOperationInProgress)
    if case .list(let title, _, let items) = picker.mode {
        #expect(title == "Locations — Right pane")
        #expect(items.count == 1)
        #expect(items[0].contains("Test drive"))
    }
    picker.onChoice?(0)
    try await settle()
    #expect(panes[1].state.directory.path == destination.path)
    #expect(panes[0].state.directory.path == root.path)
    #expect(window.firstResponder === panes[1].view)
    #expect(!controller.fileOperationInProgress)

    reader.set([FileLocation(name: "New volume", url: root)])
    controller.leftLocations(nil)
    let refreshed = try await waitForLocations(window)
    if case .list(_, _, let items) = refreshed.mode { #expect(items[0].contains("New volume")) }
    refreshed.onCancel?()
    #expect(window.firstResponder === panes[1].view)
    #expect(panes[0].state.directory.path == root.path)
    #expect(panes[1].state.directory.path == destination.path)
    #expect(!controller.fileOperationInProgress)

    // Choosing a disconnected drive leaves the previous directory intact.
    reader.set([FileLocation(name: "Disconnected", url: root.appendingPathComponent("missing"))])
    controller.leftLocations(nil)
    let disconnected = try await waitForLocations(window)
    disconnected.onChoice?(0)
    try await settle()
    #expect(panes[0].state.directory.path == root.path)
    #expect(window.firstResponder === panes[0].view)
    #expect(panes[0].view.toolTip?.hasPrefix("Cannot open folder:") == true)

    controller.isExitPromptVisible = true
    controller.leftLocations(nil)
    #expect(window.contentView?.subviews.contains { $0 is TerminalOperationDialog } == false)
}

@Test @MainActor func locationShortcutsAddressEitherPane() throws {
    let view = TerminalPaneView(name: "Test")
    var requests: [Int] = []
    view.onInput = { if case .locations(let index) = $0 { requests.append(index) } }
    for (code, flags, text): (UInt16, NSEvent.ModifierFlags, String) in [
        (122, [.option, .function], ""), (120, [.option, .function], ""),
        (18, .command, "1"), (19, .command, "2"),
    ] {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code))
        view.keyDown(with: event)
    }
    #expect(requests == [0, 1, 0, 1])
}

@Test @MainActor func locationPickerCanCancelWhileDiscovering() async throws {
    _ = NSApplication.shared
    let reader = TestLocationReader()
    let coordinator = LocationCoordinator(reader: reader)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.contentView = NSView()
    coordinator.begin(paneName: "Left pane", window: window) { _ in Issue.record("Cancelled picker chose a location") }
    let loading = try #require(window.contentView?.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    loading.onCancel?()
    #expect(!coordinator.isPresented)
    // Let the cancelled discovery task resume; it must not re-present its results.
    try await Task.sleep(for: .milliseconds(50))
    #expect(window.contentView?.subviews.isEmpty == true)
}

@Test @MainActor func optionKeyBarShowsAndInvokesLocationCommands() throws {
    let bar = TerminalKeyBar()
    bar.frame = NSRect(x: 0, y: 0, width: 1000, height: 24)
    #expect(bar.labels[1] == nil)
    bar.optionPressed = true
    #expect(bar.labels == [1: "Left", 2: "Right"])
    var commands: [TerminalKeyBar.Command] = []
    bar.onCommand = { commands.append($0) }
    for x: CGFloat in [50, 150, 450] {
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 12),
            modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        bar.mouseDown(with: click)
    }
    #expect(commands == [.leftLocations, .rightLocations])
    bar.shiftPressed = true
    #expect(bar.labels.isEmpty)
    bar.optionPressed = false
    #expect(bar.labels == [6: "Rename"])
    bar.shiftPressed = false
    #expect(bar.labels[1] == nil)
    #expect(bar.labels[3] == "View")
}
