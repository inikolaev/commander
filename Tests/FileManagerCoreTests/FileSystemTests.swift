import Foundation
import Testing
@testable import FileManagerCore

@Test(arguments: ["archive://session/", "archive://session", "file:///"])
func filesystemRootsHaveNoParent(address: String) throws {
    let root = FileSystemPath(try #require(URL(string: address)))
    #expect(root.parent == nil)
}

@Test func topLevelVirtualDirectoryReturnsToRoot() throws {
    let child = FileSystemPath(try #require(URL(string: "archive://session/folder")))
    let root = try #require(child.parent)
    #expect(root.url.host == "session")
    #expect(root.url.path.isEmpty || root.url.path == "/")
    #expect(root.parent == nil)
}

@Test func virtualAddressesNeverBecomeLocalPaths() throws {
    let url = try #require(URL(string: "archive://session/a%20b/file"))
    let path = FileSystemPath(url)
    #expect(path.localURL == nil)
    #expect(path.parent?.url.absoluteString == "archive://session/a%20b/")
    #expect(throws: (any Error).self) { try LocalFileSystem().snapshot(at: path, showHidden: true) }
}

@Test func sessionNavigationPreservesHostAndExitSelection() {
    let archive = URL(fileURLWithPath: "/tmp/example.zip")
    let session = FileSystemSession(fileSystem: LocalFileSystem(), path: FileSystemPath(URL(string: "archive://session/")!),
        hostDirectory: archive.deletingLastPathComponent(), exitSelection: archive)
    let child = session.navigating(to: URL(string: "archive://session/folder")!)
    #expect(child.hostDirectory == session.hostDirectory)
    #expect(child.exitSelection == archive)
    #expect(child.displayPath == "/tmp/example.zip!/folder")
    #expect(session.path.url.path == "/")
}
