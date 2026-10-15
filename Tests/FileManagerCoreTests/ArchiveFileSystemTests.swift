import Foundation
import Testing
import ArchiveCore
import ArchiveTestSupport
@testable import FileManagerCore

@Test func indexesImplicitDirectoriesAndPreservesNames() throws {
    let fs = try ArchiveFileSystem(url: ArchiveFixtures.url("tree.zip"))
    let entries = try fs.snapshot(at: fs.root, showHidden: false).entries
    #expect(entries.map(\.name) == ["empty", "implicit", "nested.zip", "space % # ü.txt"])
    #expect(!fs.supportsFileOperations)
    #expect(try fs.snapshot(at: fs.root, showHidden: true).entries.count == 5)
    let deep = FileSystemPath(fs.root.url.appendingPathComponent("implicit/deep"))
    let file = try #require(try fs.snapshot(at: deep, showHidden: false).entries.first)
    #expect(file.name == "hello.txt")
    #expect(!file.url.isFileURL)
    #expect(file.size == 5)
    let special = try #require(entries.last)
    #expect(special.url.lastPathComponent == special.name)
    #expect(throws: (any Error).self) { try fs.snapshot(at: FileSystemPath(URL(string: "archive://other/")!), showHidden: true) }
}

@Test(arguments: ["../escape", "ok/../../escape", "/absolute", "C:/absolute", "C:relative", "a\\b", "a/../b", "a\nb", String(repeating: "a/", count: 130)])
func rejectsUnsafeArchivePaths(path: String) {
    #expect(throws: ArchiveError.self) { try ArchiveFileSystem.normalize(path) }
}

@Test func normalizedConflictsAndLinks() throws {
    #expect(try ArchiveFileSystem.normalize("./a//./b/") == "a/b")
    let url = URL(fileURLWithPath: "/tmp/test.zip")
    for entries: [ArchiveEntry] in [
        [.init(path: "a", kind: .file), .init(path: "a/b", kind: .file)],
        [.init(path: "a/b", kind: .file), .init(path: "a", kind: .symbolicLink)],
        [.init(path: "a", kind: .file), .init(path: "./a", kind: .file)]
    ] {
        #expect(throws: ArchiveError.self) { try ArchiveFileSystem(url: url, entries: entries) }
    }
    let fs = try ArchiveFileSystem(url: url, entries: [.init(path: "a/b", kind: .file),
        .init(path: "a/", kind: .directory), .init(path: "./a", kind: .directory),
        .init(path: "link", kind: .symbolicLink), .init(path: "hard", kind: .hardLink)])
    let rows = try fs.snapshot(at: fs.root, showHidden: true).entries
    #expect(rows.first?.isDirectory == true)
    #expect(rows.filter { $0.isDirectory }.count == 1)
    #expect(rows.first { $0.name == "link" }?.isSymbolicLink == true)
    #expect(throws: ArchiveError.self) { try ArchiveFileSystem(url: ArchiveFixtures.url("unsafe.zip")) }
}

@Test func archiveRootParentAndIndependentPaneSelection() throws {
    let fs = try ArchiveFileSystem(url: ArchiveFixtures.url("tree.zip"))
    var left = PaneState(directory: fs.archiveURL.deletingLastPathComponent())
    left.replace(directory: fs.root.url, entries: try fs.snapshot(at: fs.root, showHidden: true).entries, session: fs.session)
    #expect(left.parent == fs.archiveURL.deletingLastPathComponent())
    let right = left
    left.select(2)
    left.toggleMark()
    #expect(right.markedURLs.isEmpty)
    #expect(right.selectedIndex == 0)
    #expect(left.directory.scheme == "archive")
}
