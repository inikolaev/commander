import Foundation
import Testing
@testable import FileManagerCore

@Test func filenameSearchWrapsAndSkipsParentWithoutChangingMarks() throws {
    let directory = URL(fileURLWithPath: "/tmp/search")
    func entry(_ name: String, directoryEntry: Bool = false) -> FileEntry {
        FileEntry(url: directory.appendingPathComponent(name), name: name, isDirectory: directoryEntry,
            isSymbolicLink: false, size: nil, modified: nil)
    }
    var pane = PaneState(directory: directory)
    pane.replace(directory: directory, entries: [entry("Alpha", directoryEntry: true), entry("apple.txt"), entry("notes.txt")])
    pane.select(1)
    pane.toggleMark()
    let marks = pane.markedURLs
    pane.select(3)

    #expect(pane.filenamePrefixMatch("A") == 1)
    #expect(pane.filenamePrefixMatch("APP") == 2)
    #expect(pane.filenamePrefixMatch("notes", afterCurrent: true) == 3)
    #expect(pane.filenamePrefixMatch("a", afterCurrent: true, backwards: true) == 2)
    #expect(pane.filenamePrefixMatch("..") == nil)
    #expect(pane.filenamePrefixMatch("/tmp") == nil)
    #expect(pane.filenamePrefixMatch("") == nil)
    #expect(pane.markedURLs == marks)
    #expect(pane.selectedIndex == 3)
}
