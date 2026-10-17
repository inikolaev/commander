import Foundation
import Testing
@testable import ArchiveCore

@Test func malformedAndMissingArchivesFail() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: ArchiveError.self) { try Archive.entries(at: file) }
    try Data("not an archive".utf8).write(to: file)
    #expect(throws: ArchiveError.self) { try Archive.entries(at: file) }
}

import ArchiveTestSupport

@Test(arguments: ["tree.zip", "tree.tar", "tree.tar.gz", "tree.tar.bz2", "tree.tar.xz"])
func readsReleasedLibraryFormats(name: String) throws {
    let entries = try Archive.entries(at: ArchiveFixtures.url(name))
    let file = try #require(entries.first { $0.path == "implicit/deep/hello.txt" })
    #expect(file.kind == .file)
    #expect(file.size == 5)
    if name != "tree.zip" {
        #expect(entries.first { $0.path == "link" }?.kind == .symbolicLink)
    }
}

@Test func emptyEncryptedAndEntryLimits() throws {
    #expect(try Archive.entries(at: ArchiveFixtures.url("empty.zip")).isEmpty)
    #expect(throws: ArchiveError.self) { try Archive.entries(at: ArchiveFixtures.url("encrypted.zip")) }
    #expect(throws: ArchiveError.self) { try Archive.entries(at: ArchiveFixtures.url("tree.zip"), maximumEntries: 1) }
}

@Test func refusesSpecialFilesAndDirectories() {
    #expect(throws: ArchiveError.self) { try Archive.entries(at: URL(fileURLWithPath: "/dev/null")) }
    #expect(throws: ArchiveError.self) { try Archive.entries(at: FileManager.default.temporaryDirectory) }
}

@Test(arguments: ["tree.zip", "tree.tar", "tree.tar.gz", "tree.tar.bz2", "tree.tar.xz"])
func streamsReleasedLibraryFormats(name: String) throws {
    let url = ArchiveFixtures.url(name)
    let snapshot = try Archive.snapshot(at: url)
    let entry = try #require(snapshot.entries.first { $0.path == "implicit/deep/hello.txt" })
    let stream = try ArchiveEntryStream(url: url, fingerprint: snapshot.fingerprint, entry: entry)
    #expect(try stream.read(maximumCount: 2) == Data("he".utf8))
    #expect(try stream.read(maximumCount: 2) == Data("ll".utf8))
    #expect(try stream.read(maximumCount: 2) == Data("o".utf8))
    #expect(try stream.read(maximumCount: 2).isEmpty)
    #expect(stream.isAtEnd)
}
