import AppKit
import GhosttyTerminal
import Darwin

/// A directory mailbox avoids injecting commands into the PTY: only the shell,
/// while editing a prompt or entering its next prompt, consumes directory changes.
final class TerminalDirectoryMailbox {
    let directory: URL
    private let descriptor: Int32
    private(set) var requestedDirectory: URL?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("commander-terminal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let fifo = directory.appendingPathComponent("notify").path
        guard mkfifo(fifo, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        descriptor = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func request(_ url: URL, force: Bool = false) throws {
        guard force || requestedDirectory != url else { return }
        // NUL termination preserves quotes, spaces, newlines and shell metacharacters.
        try Data((UUID().uuidString + "\0" + url.path + "\0").utf8).write(to: directory.appendingPathComponent("directory"), options: .atomic)
        requestedDirectory = url
        var byte: UInt8 = 10
        // A full FIFO already contains a wakeup; the file always holds the latest path.
        _ = Darwin.write(descriptor, &byte, 1)
    }

    deinit {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class SessionTerminal: TerminalSurfaceCloseDelegate {
    let view: AppTerminalView
    let mailbox: TerminalDirectoryMailbox
    var onExit: (() -> Void)?
    // Retained independently of visibility and window attachment.
    private let controller: TerminalController
    private var backgroundTick: Timer?

    init(directory: URL) throws {
        mailbox = try TerminalDirectoryMailbox()
        try mailbox.request(directory)
        let shellResources = Bundle.module.url(forResource: "TerminalShell", withExtension: nil)!
        controller = TerminalController {
            $0.withCustom("shell-integration", "none")
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
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.tick() }
        }
        backgroundTick = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    isolated deinit { backgroundTick?.invalidate() }

    func changeDirectory(_ directory: URL, force: Bool = false) throws { try mailbox.request(directory, force: force) }

    func terminalDidClose(processAlive: Bool) {
        // Do not destroy a surface within its Ghostty callback stack.
        Task { @MainActor [weak self] in self?.onExit?() }
    }
}

/// App commands belong to Commander; Ghostty keeps terminal copy/paste and input.
@MainActor
private final class CommanderTerminalView: AppTerminalView {
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
