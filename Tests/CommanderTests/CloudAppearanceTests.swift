import AppKit
import Testing
import FileManagerCore
@testable import Commander

@Test @MainActor func cloudIndicatorsRenderWithFileMetadata() throws {
    _ = NSApplication.shared
    var state = PaneState(directory: URL(fileURLWithPath: "/example"))
    let statuses: [CloudFileStatus] = [.notDownloaded, .downloading, .downloaded, .none]
    let names = ["Cloud document.txt", "Downloading.pdf", "Available.txt", "Local.txt"]
    let entries = zip(names, statuses).map { name, status in
        FileEntry(url: URL(fileURLWithPath: "/example/" + name), name: name,
            isDirectory: false, isSymbolicLink: false, size: 4096, modified: nil, cloudStatus: status)
    }
    state.replace(directory: state.directory, entries: entries)
    state.select(1)
    let view = TerminalPaneView(name: "Cloud preview")
    view.frame = NSRect(x: 0, y: 0, width: 720, height: 300)
    view.isActive = true
    view.update(state: state, status: "4 items")
    #expect(CloudFileAppearance.symbol(for: .downloaded) == nil)
    #expect(CloudFileAppearance.symbol(for: .none) == nil)
    for status in [CloudFileStatus.notDownloaded, .downloading] {
        let symbol = try #require(CloudFileAppearance.symbol(for: status))
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }
    if let output = ProcessInfo.processInfo.environment["COMMANDER_CLOUD_RENDER_PATH"] {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
