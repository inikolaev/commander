import AppKit
import Testing
import FileManagerCore
@testable import Commander

@Test @MainActor func fileColorsRespectCategoryPrecedence() {
    func row(_ name: String, directory: Bool = false, executable: Bool = false, hidden: Bool = false) -> PaneRow {
        .entry(FileEntry(url: URL(fileURLWithPath: "/tmp/" + name), name: name,
            isDirectory: directory, isSymbolicLink: false, size: nil, modified: nil,
            isExecutable: executable, isHidden: hidden))
    }
    let cases: [(PaneRow, NSColor)] = [
        (row("file.txt"), FileColorScheme.regularFile),
        (row("bundle.TAR.GZ"), FileColorScheme.archive),
        (row("archive.zip", executable: true), FileColorScheme.archive),
        (row("tool", executable: true), FileColorScheme.executable),
        (row("folder.zip", directory: true), FileColorScheme.directory),
        (row(".tool", executable: true), FileColorScheme.hidden),
        (row(".archive.zip"), FileColorScheme.hidden),
        (row(".config", directory: true), FileColorScheme.hidden),
        (row("flagged", hidden: true), FileColorScheme.hidden),
        (.parent(URL(fileURLWithPath: "/")), FileColorScheme.directory),
    ]
    for (entry, expected) in cases {
        #expect(FileColorScheme.color(for: entry, isSelected: false) == expected)
        #expect(FileColorScheme.color(for: entry, isSelected: true) == FileColorScheme.selected)
    }
}
