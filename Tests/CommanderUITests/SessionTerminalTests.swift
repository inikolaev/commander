import AppKit
import Foundation
import Testing
import GhosttyKit
@testable import GhosttyTerminal
@testable import CommanderUI
import FileManagerCore

@MainActor
private func terminalContents(_ terminal: SessionTerminal) throws -> String {
    let surface = try #require(terminal.view.surface?.rawValue)
    let selection = ghostty_selection_s(
        top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
        bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
        rectangle: false)
    var text = ghostty_text_s()
    try #require(ghostty_surface_read_text(surface, selection, &text))
    defer { ghostty_surface_free_text(surface, &text) }
    guard let bytes = text.text else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
}

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

@Test(arguments: ["resize> ", "context\nresize> "])
@MainActor func terminalFillsWindowAfterVerticalResizing(prompt: String) async throws {
    _ = NSApplication.shared
    let config = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: config) }
    try #"""
    HISTFILE=/dev/null
    SAVEHIST=0
    PS1='\#(prompt)'
    RPROMPT=''
    print -r -- retained-terminal-output
    TRAPWINCH() { print -r -- "$LINES $COLUMNS" >> "$COMMANDER_DIRECTORY_MAILBOX/resizes"; }
    _test_cursor() {
        local response
        printf '\e[6n'
        IFS= read -r -d R -t 1 response < /dev/tty
        print -r -- "$LINES $response" > "$COMMANDER_DIRECTORY_MAILBOX/cursor"
    }
    zle -N _test_cursor
    bindkey '^G' _test_cursor
    """#.write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let controller = CommanderWindowController()
    // Pass the fixture only to the child shell. Mutating the process environment
    // can invalidate environment pointers retained by the embedded runtime.
    controller.selectedTab.start { directory in
        try SessionTerminal(directory: directory, shellConfigurationDirectory: config)
    }
    let window = try #require(controller.window)
    defer { controller.selectedTab.closeTerminal(); window.orderOut(nil) }
    let tab = controller.selectedTab
    let terminal = try #require(tab.terminal)
    for _ in 0..<150 where !terminal.isAtPrompt { try await Task.sleep(for: .milliseconds(20)) }
    #expect(terminal.isAtPrompt)
    let cursorFile = terminal.mailbox.directory.appendingPathComponent("cursor")
    for expanded in [false, true, false] {
        if tab.isTerminalVisible != expanded {
            tab.toggleTerminal()
        }
        for height in [380, 700, 901, 500, 800] {
            window.setContentSize(NSSize(width: 1080, height: height))
            // Allow deferred grid metrics and cell-aligned layout to settle.
            for _ in 0..<10 {
                tab.root.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let root = tab.root.view
            let frame = terminal.view.convert(terminal.view.bounds, to: root)
            let available = root.bounds.height - CommanderUI.TerminalTheme.lineHeight
            #expect(abs(frame.width - root.bounds.width) < 1)
            #expect(frame.height <= available)
            #expect(frame.height > available - terminal.cellHeight)
            #expect(abs(frame.minY - CommanderUI.TerminalTheme.lineHeight) < 1)
            #expect(terminal.bottomPadding < 1)
            #expect(tab.terminal === terminal)
            try? FileManager.default.removeItem(at: cursorFile)
            #expect(terminal.view.sendKey(.g, modifiers: .ctrl))
            for _ in 0..<100 where (try? String(contentsOf: cursorFile, encoding: .utf8).hasSuffix("\n")) != true {
                try await Task.sleep(for: .milliseconds(20))
            }
            let report = try String(contentsOf: cursorFile, encoding: .utf8)
            let fields = report.components(separatedBy: " \u{1B}[")
            let rows = try #require(Int(fields[0]))
            let cursorRow = try #require(fields.count == 2 ? Int(fields[1].split(separator: ";")[0]) : nil)
            #expect(rows == Int((frame.height / terminal.cellHeight).rounded(.down)))
            #expect(cursorRow == rows, "Prompt must stay on the bottom row after resizing")
            let contents = try terminalContents(terminal)
            #expect(contents.components(separatedBy: "resize> ").count - 1 == 1,
                "Resizing to height \(height), expanded \(expanded), must not leave prompt copies")
            #expect(contents.contains("retained-terminal-output"), "Resizing must preserve previous command output")
            if prompt.contains("context") {
                #expect(contents.components(separatedBy: "context").count - 1 == 1)
            }
        }
    }
    let resizesFile = terminal.mailbox.directory.appendingPathComponent("resizes")
    try Data().write(to: resizesFile)
    let startHeight = window.contentView!.bounds.height
    let pixelSteps = Int(terminal.cellHeight)
    @MainActor final class FrameChanges { var heights: Set<CGFloat> = [] }
    let changes = FrameChanges()
    terminal.view.postsFrameChangedNotifications = true
    let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
        object: terminal.view, queue: nil) { _ in
        MainActor.assumeIsolated { _ = changes.heights.insert(terminal.view.frame.height) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    for offset in 1...pixelSteps {
        window.setContentSize(NSSize(width: 1080, height: startHeight + CGFloat(offset)))
        tab.root.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
    }
    let resizes = try String(contentsOf: resizesFile, encoding: .utf8).split(separator: "\n")
    #expect(!resizes.isEmpty)
    #expect(resizes.count <= 2, "One cell of vertical dragging must not redraw for every pixel: \(resizes)")
    #expect(changes.heights.count <= 2, "Only whole-row heights should reach the renderer: \(changes.heights)")
    let input = "printf '%s' 'wrap-start" + String(repeating: "x", count: 260) + "wrap-end'"
    #expect(terminal.view.paste(text: input))
    for _ in 0..<100 where !terminal.hasInput { try await Task.sleep(for: .milliseconds(20)) }
    #expect(terminal.hasInput)
    for height in [500, 901, 650] {
        window.setContentSize(NSSize(width: 1080, height: height))
        for _ in 0..<10 {
            tab.root.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let contents = try terminalContents(terminal)
        for text in ["resize> ", "wrap-start", "wrap-end", "retained-terminal-output"] {
            #expect(contents.components(separatedBy: text).count - 1 == 1,
                "Resizing wrapped input must retain one copy of \(text)")
        }
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

@Test @MainActor func compactPromptShortcutsPreserveShellInputThroughBothDispatchPaths() async throws {
    _ = NSApplication.shared
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let leftDirectory = directory.appendingPathComponent("left")
    let rightDirectory = directory.appendingPathComponent("right")
    for url in [directory, leftDirectory, rightDirectory] {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    defer { try? manager.removeItem(at: directory) }
    let filename = "a 'quote' $(touch INJECTED)\n日本語.txt"
    for name in [filename, "b.txt", "c.txt"] {
        try Data().write(to: leftDirectory.appendingPathComponent(name))
    }
    try Data().write(to: rightDirectory.appendingPathComponent("other file.txt"))
    try #"""
    HISTFILE=/dev/null
    SAVEHIST=0
    PS1='keys> '
    RPROMPT=''
    bindkey -e
    fc -p /dev/null 10 0
    print -s -- 'echo commander-history-older'
    print -s -- 'echo commander-history-newer'
    _test_buffer() {
        print -rn -- "$BUFFER"$'\0'"$CURSOR"$'\0' > "$COMMANDER_DIRECTORY_MAILBOX/buffer"
    }
    zle -N _test_buffer
    bindkey '^G' _test_buffer
    """#.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let window = CommanderWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let tab = CommanderTabSession(window: window, directories: [leftDirectory, rightDirectory], locationReader: LocalLocationReader())
    window.contentViewController = tab.root
    window.onTerminalInput = { tab.routeTerminalInput($0) }
    tab.start { try SessionTerminal(directory: $0, shellConfigurationDirectory: directory) }
    defer { tab.closeTerminal(); window.onTerminalInput = nil; window.orderOut(nil) }
    let terminal = try #require(tab.terminal)
    let panes = tab.root.children.compactMap { $0 as? PaneViewController }
    let left = try #require(panes[0].view as? TerminalPaneView)
    let right = try #require(panes[1].view as? TerminalPaneView)
    for _ in 0..<150 where !terminal.isAtPrompt || panes.contains(where: \.isLoading) {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(terminal.isAtPrompt && !panes.contains(where: \.isLoading))
    let fileIndex = try #require(panes[0].state.rows.firstIndex(where: { $0.name == filename }))
    left.onInput?(.select(fileIndex))
    right.onInput?(.select(1))

    func key(_ special: NSEvent.SpecialKey, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let text = String(special.unicodeScalar)
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    let reportURL = terminal.mailbox.directory.appendingPathComponent("buffer")
    func snapshot() async throws -> (text: String, cursor: Int) {
        try? manager.removeItem(at: reportURL)
        #expect(terminal.view.sendKey(.g, modifiers: .ctrl))
        for _ in 0..<100 {
            if let report = try? String(contentsOf: reportURL, encoding: .utf8) {
                let fields = report.components(separatedBy: "\0")
                // ZLE writes this report before the app's timer necessarily
                // drains its input notifications. Wait for both sides before
                // starting another action, so an earlier clear cannot restore
                // pane focus after the test has already begun inserting a name.
                if fields.count == 3, let cursor = Int(fields[1]),
                   terminal.hasInput == !fields[0].isEmpty {
                    return (fields[0], cursor)
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadUnknown)
    }
    // AppKit may offer a chord as a key equivalent before sending keyDown.
    // Exercise both routes with an empty and a nonempty prompt.
    for text in ["", "echo pending"] {
        terminal.view.sendKey(.u, modifiers: .ctrl)
        if !text.isEmpty { terminal.view.paste(text: text) }
        #expect(try await snapshot().text == text)
        window.makeFirstResponder(text.isEmpty ? left : terminal.view)
        let originalHeight = left.frame.height
        for flags: NSEvent.ModifierFlags in [.shift, .option, [.option, .shift], [.control, .option]] {
            for (special, code): (NSEvent.SpecialKey, UInt16) in [(.carriageReturn, 36), (.enter, 76)] {
                let event = try key(special, code: code, flags: flags)
                #expect(window.performKeyEquivalent(with: event))
                window.sendEvent(event)
            }
        }
        for (special, code): (NSEvent.SpecialKey, UInt16) in [(.downArrow, 125), (.upArrow, 126), (.rightArrow, 124), (.leftArrow, 123)] {
            left.onInput?(.select(fileIndex))
            let event = try key(special, code: code, flags: [.shift, .function, .numericPad])
            #expect(window.performKeyEquivalent(with: event))
            #expect(panes[0].state.selectedIndex != fileIndex)
            #expect(!panes[0].state.markedURLs.isEmpty)
        }
        #expect(try await snapshot().text == text)
        tab.root.view.layoutSubtreeIfNeeded()
        #expect(terminal.inputRows == 1)
        #expect(left.frame.height == originalHeight)
        #expect(!tab.isTerminalVisible)
    }

    // Insertion uses the cursor entry even when other files are marked, and
    // preserves punctuation, Unicode and newlines as one literal shell argument.
    left.onInput?(.select(fileIndex))
    terminal.view.sendKey(.u, modifiers: .ctrl)
    _ = try await snapshot()
    window.makeFirstResponder(left)
    let insert = try key(.carriageReturn, code: 36, flags: .control)
    #expect(window.performKeyEquivalent(with: insert))
    var expected = SessionTerminal.shellArgument(filename) + " "
    #expect(try await snapshot().text == expected)
    #expect(window.firstResponder === terminal.view)
    window.sendEvent(try key(.carriageReturn, code: 36, flags: [.control, .shift]))
    expected += SessionTerminal.shellArgument("other file.txt") + " "
    #expect(try await snapshot().text == expected)
    let controlJ = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: "\n", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
    #expect(window.performKeyEquivalent(with: controlJ))
    expected += SessionTerminal.shellArgument(filename) + " "
    #expect(try await snapshot().text == expected)
    #expect(!expected.contains("\n"))
    #expect(!manager.fileExists(atPath: leftDirectory.appendingPathComponent("INJECTED").path))
    #expect(!tab.isTerminalVisible)

    terminal.view.sendKey(.u, modifiers: .ctrl)
    terminal.view.paste(text: "one two three")
    #expect(try await snapshot().cursor == 13)
    #expect(window.performKeyEquivalent(with: try key(.leftArrow, code: 123, flags: .control)))
    #expect(try await snapshot().cursor == 8)
    window.sendEvent(try key(.leftArrow, code: 123, flags: .option))
    #expect(try await snapshot().cursor == 4)
    window.sendEvent(try key(.rightArrow, code: 124, flags: .control))
    let wordRight = try await snapshot()
    #expect(wordRight.cursor == 8) // zsh forward-word includes the following space.
    window.sendEvent(try key(.rightArrow, code: 124, flags: .option))
    #expect(try await snapshot().cursor == 13)
    window.sendEvent(try key(.home, code: 115, flags: .control))
    #expect(try await snapshot().cursor == 0)
    window.sendEvent(insert)
    #expect(try await snapshot().text == SessionTerminal.shellArgument(filename) + " one two three")
    window.sendEvent(try key(.end, code: 119, flags: .control))
    let final = try await snapshot()
    #expect(final.cursor == final.text.unicodeScalars.count)

    let historyUp = try key(.upArrow, code: 126, flags: [.option, .function, .numericPad])
    let historyDown = try key(.downArrow, code: 125, flags: [.option, .function, .numericPad])
    for keyEquivalent in [true, false] {
        for draft in ["", "echo unfinished"] {
            terminal.view.sendKey(.u, modifiers: .ctrl)
            if !draft.isEmpty { terminal.view.paste(text: draft) }
            #expect(try await snapshot().text == draft)
            window.makeFirstResponder(draft.isEmpty ? left : terminal.view)
            let selection = panes[0].state.selectedIndex
            let marks = panes[0].state.markedURLs
            // Both dispatch paths must recall actual history and restore the
            // unfinished command without changing the file cursor or marks.
            for (event, expected) in [
                (historyDown, draft),
                (historyUp, "echo commander-history-newer"),
                (historyUp, "echo commander-history-older"),
                (historyDown, "echo commander-history-newer"),
                (historyDown, draft),
            ] {
                if keyEquivalent { #expect(window.performKeyEquivalent(with: event)) }
                else { window.sendEvent(event) }
                let input = try await snapshot()
                #expect(input.text == expected)
                #expect(panes[0].state.selectedIndex == selection)
                #expect(panes[0].state.markedURLs == marks)
                #expect(!tab.isTerminalVisible)
            }
        }
    }

    tab.toggleTerminal()
    #expect(!tab.routeTerminalInput(insert))
    #expect(!tab.routeTerminalInput(controlJ))
    #expect(!tab.routeTerminalInput(try key(.carriageReturn, code: 36, flags: .option)))
    #expect(!tab.routeTerminalInput(try key(.leftArrow, code: 123, flags: .shift)))
    #expect(!tab.routeTerminalInput(historyUp))
    #expect(!tab.routeTerminalInput(historyDown))
}

@Test @MainActor func insertedFilenamesRoundTripThroughZshQuoting() throws {
    for name in ["plain.txt", "..", "quote' space \\ $HOME `whoami` ! * ?.txt", "日本語\n\t\r\u{1B}.txt", ""] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "printf '%s' " + SessionTerminal.shellArgument(name)]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == name)
    }
}
