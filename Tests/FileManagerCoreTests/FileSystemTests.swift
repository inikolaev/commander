import Foundation
import Testing
@testable import FileManagerCore

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
