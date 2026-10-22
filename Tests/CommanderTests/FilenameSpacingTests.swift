import AppKit
import Testing
import FileManagerCore
@testable import Commander

@Test @MainActor func truncatedFilenamesKeepIdenticalPrefixSpacing() throws {
    _ = NSApplication.shared
    let names = [
        "1590 2022 Märkätilan kopokartoitusraportti, Tapiolan Lämpö.pdf",
        "1590 2023 Energiatodistus A-talo.pdf",
        "1590 2024 Ikkunoiden uusimisen hankesuunnitelma, Conditio.pdf",
    ]
    var state = PaneState(directory: URL(fileURLWithPath: "/"))
    state.replace(directory: state.directory, entries: names.map {
        FileEntry(url: URL(fileURLWithPath: "/" + $0), name: $0, isDirectory: false,
            isSymbolicLink: false, size: nil, modified: nil)
    })
    let view = TerminalPaneView(name: "Spacing")
    view.frame = NSRect(x: 0, y: 0, width: 800, height: 240)
    view.update(state: state, status: "3 items")
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let pixels = try #require(bitmap.bitmapData)
    let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    let cellWidth = ("0" as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
    let x = Int(8 * scale)
    let width = Int(6 * cellWidth * scale) // Shared prefix "1590 2".
    let height = Int(TerminalTheme.lineHeight * scale)
    let bytesPerPixel = bitmap.bitsPerPixel / 8
    func prefixPixels(row: Int) -> [UInt8] {
        let y = Int(view.geometry.listTop * scale) + row * height
        return (y..<(y + height)).flatMap { scanline in
            let start = scanline * bitmap.bytesPerRow + x * bytesPerPixel
            return Array(UnsafeBufferPointer(start: pixels + start, count: width * bytesPerPixel))
        }
    }
    #expect(prefixPixels(row: 0) == prefixPixels(row: 1))
    #expect(prefixPixels(row: 1) == prefixPixels(row: 2))
    if let output = ProcessInfo.processInfo.environment["COMMANDER_SPACING_RENDER_PATH"] {
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
