import AppKit
import Foundation
import Testing
@testable import CommanderUI

@Test func terminalMailboxPreservesLiteralPathsAndCleansUp() throws {
    var mailbox: TerminalDirectoryMailbox? = try TerminalDirectoryMailbox()
    let directory = try #require(mailbox?.directory)
    let path = URL(fileURLWithPath: "/tmp/quote' $(example)\ntrailing\n")
    try mailbox?.request(path)
    let first = try Data(contentsOf: directory.appendingPathComponent("directory"))
    #expect(first.suffix(path.path.utf8.count + 1) == Data((path.path + "\0").utf8))
    try mailbox?.request(path, force: true)
    #expect(try Data(contentsOf: directory.appendingPathComponent("directory")) != first)
    mailbox = nil
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test @MainActor func terminalShortcutRequiresOnlyCommand() throws {
    for (flags, expected) in [(NSEvent.ModifierFlags.shift, false), (.command, true), ([.command, .option], false), ([.command, .control], false), ([], false), ([.shift, .command], false), ([.shift, .control], false), ([.shift, .option], false)] {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "O", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
        #expect(CommanderWindow.isTerminalToggle(event) == expected)
    }
}

@Test @MainActor func terminalSurvivesHidingAndTabSwitching() throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    let first = controller.selectedTab
    let pane = first.root.children[0].view
    controller.window?.makeFirstResponder(pane)
    #expect(first.terminal == nil)
    #expect(first.toggleTerminal())
    let terminal = try #require(first.terminal)
    #expect(first.isTerminalVisible)
    #expect(controller.window?.firstResponder === terminal.view)
    #expect(first.toggleTerminal())
    #expect(!first.isTerminalVisible)
    #expect(controller.window?.firstResponder === pane)
    #expect(first.terminal === terminal)
    #expect(terminal.view.isHidden)
    let requestFile = terminal.mailbox.directory.appendingPathComponent("directory")
    let request = try Data(contentsOf: requestFile)
    let panes = first.root.children.compactMap { $0 as? PaneViewController }
    panes[1].onAction?(.activate)
    #expect(try Data(contentsOf: requestFile) != request)
    controller.newTab(nil)
    let second = controller.selectedTab
    #expect(second.toggleTerminal())
    #expect(second.terminal !== terminal)
    controller.selectTab(id: first.id)
    #expect(first.toggleTerminal())
    #expect(first.terminal === terminal)
    #expect(controller.window?.firstResponder === terminal.view)
    controller.selectTab(id: second.id)
    controller.closeTab(nil)
    #expect(second.terminal == nil)
    #expect(first.terminal === terminal)
    first.closeTerminal()
    controller.window?.orderOut(nil)
}

@Test @MainActor func commandOTogglesFromTerminalThroughKeyEquivalentDispatch() throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    let window = try #require(controller.window as? CommanderWindow)
    defer { controller.selectedTab.closeTerminal(); window.orderOut(nil) }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 1, windowNumber: window.windowNumber,
        context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
    #expect(window.performKeyEquivalent(with: event))
    let terminal = try #require(controller.selectedTab.terminal)
    #expect(window.firstResponder === terminal.view)
    #expect(window.performKeyEquivalent(with: event))
    #expect(!controller.selectedTab.isTerminalVisible)
    #expect(controller.selectedTab.terminal === terminal)
    #expect(window.firstResponder !== terminal.view)
}
