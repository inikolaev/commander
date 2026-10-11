import AppKit
import GhosttyTerminal
import Darwin

/// A directory mailbox avoids injecting commands into the PTY: only the shell,
/// while editing a prompt or entering its next prompt, consumes directory changes.
final class TerminalDirectoryMailbox {
    let directory: URL
    private let descriptor: Int32
    private let eventsDescriptor: Int32
    private let responseDescriptor: Int32
    private var pendingEvents = Data()
    private(set) var requestedDirectory: URL?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("commander-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var descriptors: [Int32] = []
        do {
            for name in ["notify", "events", "responses"] {
                let fifo = directory.appendingPathComponent(name).path
                guard mkfifo(fifo, 0o600) == 0 else { throw POSIXError(.EIO) }
                let fd = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                descriptors.append(fd)
            }
            try Data("compact".utf8).write(to: directory.appendingPathComponent("mode"), options: .atomic)
        } catch {
            descriptors.forEach { Darwin.close($0) }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        descriptor = descriptors[0]
        eventsDescriptor = descriptors[1]
        responseDescriptor = descriptors[2]
    }

    func request(_ url: URL, force: Bool = false) throws {
        guard force || requestedDirectory != url else { return }
        // NUL termination preserves quotes, spaces, newlines and shell metacharacters.
        try Data((UUID().uuidString + "\0" + url.path + "\0").utf8).write(to: directory.appendingPathComponent("directory"), options: .atomic)
        requestedDirectory = url
        notifyShell()
    }

    private func notifyShell() {
        var byte: UInt8 = 10
        // A full FIFO already contains a wakeup; the file always holds the latest path.
        _ = Darwin.write(descriptor, &byte, 1)
    }

    func setCompact(_ compact: Bool) throws {
        try Data((compact ? "compact" : "full").utf8)
            .write(to: directory.appendingPathComponent("mode"), options: .atomic)
        // Mode changes only alter input routing; they do not redraw the prompt.
    }

    func acknowledge(_ token: String) {
        let bytes = Array((token + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(responseDescriptor, $0.baseAddress, $0.count) }
    }

    func drainEvents() -> [String] {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(eventsDescriptor, &bytes, bytes.count)
            guard count > 0 else { break }
            pendingEvents.append(contentsOf: bytes.prefix(count))
        }
        var result: [String] = []
        while let newline = pendingEvents.firstIndex(of: 10) {
            result.append(String(decoding: pendingEvents[..<newline], as: UTF8.self))
            pendingEvents.removeSubrange(...newline)
        }
        return result
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(eventsDescriptor)
        Darwin.close(responseDescriptor)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class SessionTerminal: TerminalSurfaceCloseDelegate, TerminalSurfaceGridResizeDelegate {
    let view: CommanderTerminalView
    let mailbox: TerminalDirectoryMailbox
    var onExit: (() -> Void)?
    var onOpenSelection: (() -> Void)?
    var onExecute: (() -> Bool)?
    var onPrompt: ((Int) -> Void)?
    var onInputChanged: ((Bool, Int) -> Void)?
    var onCellHeightChanged: (() -> Void)?
    private(set) var hasInput = false
    private(set) var isAtPrompt = false
    private(set) var cellHeight: CGFloat = 20
    private(set) var bottomPadding: CGFloat = 0
    private(set) var inputRows = 1
    // Retained independently of visibility and window attachment.
    private let controller: TerminalController
    private var backgroundTick: Timer?

    init(directory: URL) throws {
        mailbox = try TerminalDirectoryMailbox()
        try mailbox.request(directory)
        let shellResources = Bundle.module.url(forResource: "TerminalShell", withExtension: nil)!
        controller = TerminalController {
            $0.withCustom("shell-integration", "none")
            $0.withCustom("window-padding-x", "0")
            $0.withCustom("window-padding-y", "0")
        }
        view = CommanderTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        var environment = [
            "ZDOTDIR": shellResources.path,
            "COMMANDER_SHELL_RESOURCES": shellResources.path,
            "COMMANDER_DIRECTORY_MAILBOX": mailbox.directory.path,
        ]
        if let original = ProcessInfo.processInfo.environment["ZDOTDIR"] {
            environment["COMMANDER_ORIGINAL_ZDOTDIR"] = original
        }
        view.configuration = TerminalSurfaceOptions(
            workingDirectory: directory.path, envVars: environment,
            command: "/bin/zsh -l", waitAfterCommand: false)
        view.controller = controller
        view.delegate = self
        // The wrapper suspends ticks when a tab detaches from its window. Keep
        // draining Ghostty's bounded event mailbox so background jobs cannot
        // stall on title, directory, or exit notifications in inactive tabs.
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller.tick()
                for event in self.mailbox.drainEvents() { self.handleShellEvent(event) }
            }
        }
        backgroundTick = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    isolated deinit { backgroundTick?.invalidate() }

    func changeDirectory(_ directory: URL, force: Bool = false) throws { try mailbox.request(directory, force: force) }

    func setCompact(_ compact: Bool) throws {
        try mailbox.setCompact(compact)
        view.isCompact = compact
        if compact { view.performBindingAction("scroll_to_bottom") }
    }

    func handleShellEvent(_ event: String) {
        let fields = event.split(separator: " ")
        guard let kind = fields.first else { return }
        switch kind {
        case "open": onOpenSelection?()
        case "execute":
            guard fields.count == 2 else { return }
            guard onExecute?() == true else { return }
            isAtPrompt = false
            // The caller removes the pane overlay before acknowledging. The
            // shell's accept-line widget cannot start the command before this.
            mailbox.acknowledge(String(fields[1]))
        case "running": isAtPrompt = false
        case "prompt":
            guard fields.count == 2, let status = Int(fields[1]) else { return }
            isAtPrompt = true
            hasInput = false
            inputRows = 1
            onPrompt?(status)
            onInputChanged?(false, inputRows)
        case "input":
            guard fields.count == 3, let rows = Int(fields[2]) else { return }
            hasInput = fields[1] == "1"
            // ZLE does not move the prompt back down when a wrapped buffer
            // shrinks. Keep its space exposed until the next anchored prompt.
            inputRows = max(inputRows, min(6, max(1, rows)))
            onInputChanged?(hasInput, inputRows)
            if view.isCompact { view.performBindingAction("scroll_to_bottom") }
        default: break
        }
    }

    func terminalDidResize(_ size: TerminalGridMetrics) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let height = CGFloat(size.cellHeightPixels) / scale
        guard height > 0 else { return }
        let padding = max(0, view.bounds.height - CGFloat(size.rows) * height)
        guard abs(height - cellHeight) > 0.1 || abs(padding - bottomPadding) > 0.1 else { return }
        cellHeight = height
        bottomPadding = padding
        // Layout must not reenter a Ghostty resize callback.
        Task { @MainActor [weak self] in self?.onCellHeightChanged?() }
    }

    func terminalDidClose(processAlive: Bool) {
        // Do not destroy a surface within its Ghostty callback stack.
        Task { @MainActor [weak self] in self?.onExit?() }
    }
}

/// App commands belong to Commander; Ghostty keeps terminal copy/paste and input.
@MainActor
final class CommanderTerminalView: AppTerminalView {
    var isCompact = true

    override func scrollWheel(with event: NSEvent) {
        guard !isCompact else { return }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isCompact {
            if [.pageUp, .pageDown].contains(event.specialKey) { return }
            if event.modifierFlags.contains(.command),
               [.home, .end, .upArrow, .downArrow].contains(event.specialKey) { return }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           ["q", "t", "w", "h", "m", "[", "]", "{", "}"].contains(key),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
