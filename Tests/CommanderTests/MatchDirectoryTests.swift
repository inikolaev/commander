import AppKit
import Foundation
import Testing
@testable import Commander

@Test @MainActor func commandDMatchesDirectoryInEitherDirectionWithoutChangingFocus() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let leftDirectory = root.appendingPathComponent("left")
    let rightDirectory = root.appendingPathComponent("right")
    try fm.createDirectory(at: leftDirectory, withIntermediateDirectories: true)
    try fm.createDirectory(at: rightDirectory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let child = leftDirectory.appendingPathComponent("child")
    try fm.createDirectory(at: child, withIntermediateDirectories: false)
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    defer { window.orderOut(nil) }
    let panes = try #require(window.contentViewController?.children.compactMap { $0 as? PaneViewController })
    #expect(panes.count == 2)
    func settle() async throws {
        for _ in 0..<200 {
            if panes.allSatisfy({ !$0.isLoading }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Directory loads did not finish")
    }
    panes[0].load(leftDirectory, preferredSelection: child)
    panes[1].load(rightDirectory)
    try await settle()
    panes[0].onAction?(.activate)
    panes[0].focus()
    let view = try #require(panes[0].view as? TerminalPaneView)
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "d",
        charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
    view.keyDown(with: key)
    try await settle()
    #expect(panes[1].state.directory.path == leftDirectory.path)
    #expect(panes[1].state.selectedRow?.url.resolvingSymlinksInPath().path == child.resolvingSymlinksInPath().path)
    #expect(window.firstResponder === view)
    // A selected subdirectory must not be entered in the other pane.
    #expect(panes[1].state.directory.path != child.path)
    panes[1].load(rightDirectory)
    try await settle()
    panes[1].onAction?(.activate)
    panes[1].focus()
    controller.matchDirectory(nil)
    try await settle()
    #expect(panes[0].state.directory.path == rightDirectory.path)
    #expect(window.firstResponder === panes[1].view)
    controller.isExitPromptVisible = true
    panes[1].load(leftDirectory)
    try await settle()
    controller.matchDirectory(nil)
    #expect(!panes[0].isLoading)
    #expect(panes[0].state.directory.path == rightDirectory.path)
}
