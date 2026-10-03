import Foundation
import Testing
@testable import FileManagerCore

private let identityDirectory = URL(fileURLWithPath: "/example", isDirectory: true)

private func identityEntry(_ name: String, inode: UInt64?, device: Int32 = 1) -> FileEntry {
    FileEntry(url: identityDirectory.appendingPathComponent(name), name: name,
        isDirectory: false, isSymbolicLink: false, size: nil, modified: nil,
        identity: inode.map { FileIdentity(device: device, inode: $0) })
}

@Test func renameKeepsSelectionAndMarksEvenWhenOldNameIsReused() {
    let old = identityEntry("old", inode: 1)
    let renamed = identityEntry("renamed", inode: 1)
    let replacement = identityEntry("old", inode: 2)
    var pane = PaneState(directory: identityDirectory)
    pane.replace(directory: identityDirectory, entries: [old], preferredSelection: old.url)
    pane.toggleMark()
    pane.replace(directory: identityDirectory, entries: [replacement, renamed], preferredSelection: old.url)
    #expect(pane.selectedRow?.url == renamed.url)
    #expect(pane.markedURLs == [renamed.url])
    #expect(pane.markedEntries == [renamed])
}

@Test func identityRefreshKeepsExplicitSelectionAndPathFallbacks() {
    let old = identityEntry("old", inode: 1)
    let renamed = identityEntry("renamed", inode: 1)
    let explicit = identityEntry("explicit", inode: 2)
    var pane = PaneState(directory: identityDirectory)
    pane.replace(directory: identityDirectory, entries: [old], preferredSelection: old.url)
    pane.replace(directory: identityDirectory, entries: [renamed, explicit], preferredSelection: explicit.url)
    #expect(pane.selectedRow?.url == explicit.url)
    pane.toggleMark()
    // Atomic saves replace the inode at the same path.
    let saved = identityEntry("explicit", inode: 3)
    pane.replace(directory: identityDirectory, entries: [renamed, saved], preferredSelection: explicit.url)
    #expect(pane.selectedRow?.url == saved.url)
    #expect(pane.markedURLs == [saved.url])
    let unavailable = identityEntry("explicit", inode: nil)
    pane.replace(directory: identityDirectory, entries: [unavailable], preferredSelection: saved.url)
    #expect(pane.selectedRow?.url == unavailable.url)
    #expect(pane.markedURLs == [unavailable.url])
}

@Test func identityIncludesDeviceAndDoesNotGuessAmbiguousHardLinks() {
    let first = identityEntry("first", inode: 1)
    let link = identityEntry("link", inode: 1)
    var pane = PaneState(directory: identityDirectory)
    pane.replace(directory: identityDirectory, entries: [first, link], preferredSelection: link.url)
    pane.toggleMark()
    pane.replace(directory: identityDirectory, entries: [link, first], preferredSelection: link.url)
    #expect(pane.selectedRow?.url == link.url)
    #expect(pane.markedURLs == [link.url])
    pane.replace(directory: identityDirectory, entries: [first], preferredSelection: link.url)
    #expect(pane.selectedRow?.name == "..")
    #expect(pane.markedURLs.isEmpty)
    pane.replace(directory: identityDirectory, entries: [first], preferredSelection: first.url)
    pane.toggleMark()
    pane.replace(directory: identityDirectory, entries: [identityEntry("unrelated", inode: 1, device: 2)], preferredSelection: first.url)
    #expect(pane.selectedRow?.name == "..")
    #expect(pane.markedURLs.isEmpty)
}

@Test func readerIdentitySurvivesRenameForFilesDirectoriesAndSymlinks() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    try Data().write(to: directory.appendingPathComponent("file"))
    try fm.createDirectory(at: directory.appendingPathComponent("folder"), withIntermediateDirectories: false)
    try fm.createSymbolicLink(atPath: directory.appendingPathComponent("link").path, withDestinationPath: "file")
    let reader = LocalDirectoryReader()
    let before = try reader.entries(at: directory, showHidden: false)
    #expect(Set(before.compactMap(\.identity)).count == 3)
    for entry in before {
        try fm.moveItem(at: entry.url, to: directory.appendingPathComponent("renamed-" + entry.name))
    }
    let after = try reader.entries(at: directory, showHidden: false)
    for entry in before {
        let identity = try #require(entry.identity)
        #expect(after.first { $0.name == "renamed-" + entry.name }?.identity == identity)
    }
}
