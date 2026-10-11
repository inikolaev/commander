import Foundation
import GhosttyTerminal

/// Runs through the same SwiftPM accessors used at startup, without launching UI.
public enum BundledResourceCheck {
    public static func verify() throws {
        let resources = Bundle.main.resourceURL!.standardizedFileURL.path + "/"
        let files: [URL?] = [
            Bundle.module.url(forResource: "TerminalShell", withExtension: nil)?
                .appendingPathComponent(".zshenv"),
            Bundle.module.url(forResource: "TerminalShell", withExtension: nil)?
                .appendingPathComponent("integration.zsh"),
            GhosttyRuntimeResources.directoryURL?
                .appendingPathComponent("shell-integration/zsh/ghostty-integration"),
            GhosttyRuntimeResources.terminfoDirectoryURL?
                .appendingPathComponent("78/xterm-ghostty"),
        ]
        for file in files {
            guard let file, file.standardizedFileURL.path.hasPrefix(resources),
                  FileManager.default.isReadableFile(atPath: file.path) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "Missing app-bundled resource: \(file?.path ?? "unresolved")"
                ])
            }
        }
    }
}
