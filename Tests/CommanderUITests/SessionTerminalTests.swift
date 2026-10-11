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
    terminal.handleShellEvent("prompt 0")
    #expect(first.toggleTerminal())
    #expect(!first.isTerminalVisible)
    #expect(controller.window?.firstResponder === pane)
    #expect(first.terminal === terminal)
    #expect(!terminal.view.isHidden)
    #expect(terminal.view.isCompact)
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
    terminal.handleShellEvent("prompt 0")
    #expect(window.performKeyEquivalent(with: event))
    #expect(!controller.selectedTab.isTerminalVisible)
    #expect(controller.selectedTab.terminal === terminal)
    #expect(window.firstResponder !== terminal.view)
}

@Test @MainActor func compactPromptExpandsBeforeExecutionAndRestoresOnCompletion() throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    defer { controller.selectedTab.closeTerminal(); controller.window?.orderOut(nil) }
    controller.start()
    let tab = controller.selectedTab
    let terminal = try #require(tab.terminal)
    tab.root.view.layoutSubtreeIfNeeded()
    #expect(!tab.isTerminalVisible)
    #expect(terminal.view.isCompact)
    let size = terminal.view.frame.size
    #expect(size.height > 200)
    let pane = try #require(tab.root.children.first?.view)
    #expect(!pane.isHidden)
    terminal.handleShellEvent("prompt 0")
    terminal.handleShellEvent("execute test-1")
    #expect(tab.isTerminalVisible)
    #expect(!terminal.view.isCompact)
    #expect(terminal.view.frame.size == size)
    #expect(pane.isHidden)
    // Cmd-O must be blocked even before the preexec notification arrives.
    #expect(!terminal.isAtPrompt)
    #expect(tab.toggleTerminal())
    #expect(tab.isTerminalVisible)
    terminal.handleShellEvent("running")
    #expect(tab.toggleTerminal())
    #expect(tab.isTerminalVisible)
    #expect(controller.window?.firstResponder === terminal.view)
    terminal.handleShellEvent("prompt 0")
    #expect(!tab.isTerminalVisible)
    #expect(terminal.view.isCompact)
    #expect(tab.terminal === terminal)
    #expect(terminal.view.frame.size == size)
    #expect(!pane.isHidden)
    terminal.handleShellEvent("input 1 4")
    tab.root.view.layoutSubtreeIfNeeded()
    #expect(terminal.view.frame.size == size) // Wrapped input changes only the overlay.
    terminal.handleShellEvent("input 0 1")
    #expect(terminal.inputRows == 4) // Erasing must not cover the prompt left above the bottom.
    terminal.handleShellEvent("prompt 0")
    #expect(terminal.inputRows == 1)
    terminal.handleShellEvent("execute test-2")
    terminal.handleShellEvent("prompt 1")
    #expect(!tab.isTerminalVisible) // Failure is still completion.
    terminal.handleShellEvent("execute test-3")
    terminal.handleShellEvent("prompt 130")
    #expect(!tab.isTerminalVisible) // Interrupted commands also return to panes.
    tab.toggleTerminal()
    terminal.handleShellEvent("prompt 0")
    #expect(tab.isTerminalVisible) // Explicit Cmd-O view never auto-collapses.
    terminal.handleShellEvent("running")
    #expect(tab.toggleTerminal())
    #expect(tab.isTerminalVisible)
    terminal.handleShellEvent("prompt 0")
    #expect(tab.isTerminalVisible)
    #expect(tab.toggleTerminal())
    #expect(!tab.isTerminalVisible) // Manual toggle works again at the prompt.
}

@Test @MainActor func paneTypingUsesTerminalAndErasingRestoresPaneFocus() throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    defer { controller.selectedTab.closeTerminal(); controller.window?.orderOut(nil) }
    controller.start()
    let tab = controller.selectedTab
    let terminal = try #require(tab.terminal)
    let pane = tab.root.children[0].view
    func key(_ text: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: controller.window!.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    #expect(tab.routeTerminalInput(try key("a", code: 0)))
    #expect(controller.window?.firstResponder === terminal.view)
    terminal.handleShellEvent("input 0 1") // A delayed initial notification must not steal focus.
    #expect(controller.window?.firstResponder === terminal.view)
    terminal.handleShellEvent("input 1 1")
    terminal.handleShellEvent("input 0 1")
    #expect(controller.window?.firstResponder === pane)
    #expect(!tab.routeTerminalInput(try key(" ", code: 49))) // Pane marking remains available.
    #expect(tab.routeTerminalInput(try key("\r", code: 36))) // Shell decides whether Enter opens or executes.
    #expect(!tab.isTerminalVisible) // No expansion until the shell acknowledges nonempty input.
}

@Test @MainActor func compactPromptKeepsNavigationAndTabWithPanesWhileEditing() throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    defer { controller.selectedTab.closeTerminal(); controller.window?.orderOut(nil) }
    controller.start()
    let tab = controller.selectedTab
    let terminal = try #require(tab.terminal)
    let panes = tab.root.children.compactMap { $0 as? PaneViewController }
    let left = try #require(panes[0].view as? TerminalPaneView)
    let right = try #require(panes[1].view as? TerminalPaneView)
    func key(_ special: NSEvent.SpecialKey) throws -> NSEvent {
        let text = String(special.unicodeScalar)
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: special == .backTab ? .shift : [], timestamp: 1,
            windowNumber: controller.window!.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
    }
    controller.window?.makeFirstResponder(terminal.view)
    terminal.handleShellEvent("input 1 1")
    for arrow: NSEvent.SpecialKey in [.upArrow, .downArrow, .leftArrow, .rightArrow] {
        #expect(tab.routeTerminalInput(try key(arrow)))
        #expect(controller.window?.firstResponder === terminal.view)
    }
    #expect(tab.routeTerminalInput(try key(.tab)))
    #expect(right.isActive && !left.isActive)
    #expect(!tab.isTerminalVisible)
    #expect(controller.window?.firstResponder === terminal.view)
    #expect(terminal.hasInput)
    #expect(!tab.routeTerminalInput(try key(.backspace))) // Continue editing in zsh.
    #expect(tab.routeTerminalInput(try key(.backTab)))
    #expect(left.isActive && !right.isActive)
    tab.toggleTerminal()
    #expect(!tab.routeTerminalInput(try key(.downArrow)))
    #expect(!tab.routeTerminalInput(try key(.tab))) // Expanded terminal retains normal keys.
}
