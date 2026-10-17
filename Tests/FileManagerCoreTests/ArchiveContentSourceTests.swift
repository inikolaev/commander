import Foundation
import Testing
import ArchiveCore
import ArchiveTestSupport
@testable import FileManagerCore

private func archiveSource(memoryLimit: Int = 32, expandedLimit: Int64 = 1_000_000) throws -> ArchiveFileContentSource {
    let url = ArchiveFixtures.url("viewer.zip")
    let snapshot = try Archive.snapshot(at: url)
    let entry = try #require(snapshot.entries.first { $0.path == "large.txt" })
    return try ArchiveFileContentSource(url: url, fingerprint: snapshot.fingerprint, entry: entry,
        memoryLimit: memoryLimit, expandedLimit: expandedLimit)
}

@Test func archiveSourceSpillsAndServesBackwardReadsWithoutDecompression() async throws {
    let source = try archiveSource(memoryLimit: 70_000)
    #expect(try await source.read(at: 0, count: 17) == Data("0123456789abcdef\n".utf8))
    #expect(await source.materializedBytes == 65_536)
    #expect(await source.usesDisk == false)
    let second = try await source.read(at: 65_530, count: 30)
    let expected = Data(String(repeating: "0123456789abcdef\n", count: 20_000).utf8)
    #expect(second == expected.subdata(in: 65_530..<65_560))
    #expect(await source.usesDisk)
    let prepared = await source.materializedBytes
    #expect(try await source.read(at: 2, count: 12) == expected.subdata(in: 2..<14))
    #expect(await source.materializedBytes == prepared)
    #expect(try await source.length() == 340_000)
    #expect(try await source.read(at: 339_998, count: 10) == expected.suffix(2))
    #expect(try await source.read(at: 400_000, count: 10).isEmpty)
}

@Test func archiveLimitsFailWithoutLeavingSpillAndStayFailed() async throws {
    let source = try archiveSource(expandedLimit: 100_000)
    _ = try await source.read(at: 0, count: 1)
    #expect(await source.usesDisk)
    await #expect(throws: ArchiveError.self) { try await source.read(at: 100_000, count: 1) }
    #expect(await source.usesDisk == false)
    await #expect(throws: ArchiveError.self) { try await source.read(at: 0, count: 1) }
}

@Test func cancelledArchiveRequestCanBeReadAgain() async throws {
    let source = try archiveSource()
    let task = Task {
        while !Task.isCancelled { await Task.yield() }
        return try await source.read(at: 200_000, count: 20)
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    #expect(try await source.read(at: 0, count: 17) == Data("0123456789abcdef\n".utf8))
}

@Test func archiveSnapshotRejectsReplacementAndInPlaceMutation() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let data = try Data(contentsOf: ArchiveFixtures.url("viewer.zip"))
    try data.write(to: url)
    let snapshot = try Archive.snapshot(at: url)
    let entry = try #require(snapshot.entries.first { $0.path == "large.txt" })
    let source = try ArchiveFileContentSource(url: url, fingerprint: snapshot.fingerprint, entry: entry)
    _ = try await source.read(at: 0, count: 1)
    let file = try FileHandle(forWritingTo: url)
    try file.seek(toOffset: UInt64(data.count - 1))
    try file.write(contentsOf: Data([0x7f]))
    try file.close()
    await #expect(throws: ArchiveError.self) { try await source.read(at: 0, count: 1) }
    try data.write(to: url, options: .atomic)
    #expect(throws: ArchiveError.self) { try ArchiveFileContentSource(url: url, fingerprint: snapshot.fingerprint, entry: entry) }
}

@Test func emptyArchiveFileAndLinks() async throws {
    let url = ArchiveFixtures.url("viewer.zip")
    let snapshot = try Archive.snapshot(at: url)
    let entry = try #require(snapshot.entries.first { $0.path == "empty.txt" })
    let source = try ArchiveFileContentSource(url: url, fingerprint: snapshot.fingerprint, entry: entry)
    #expect(try await source.length() == 0)
    #expect(try await source.read(at: 0, count: 1).isEmpty)
    #expect(throws: ArchiveError.self) {
        try ArchiveEntryStream(url: url, fingerprint: snapshot.fingerprint, entry: ArchiveEntry(path: "link", kind: .hardLink))
    }
}

@Test func corruptPayloadIsReportedWhenRead() async throws {
    let url = ArchiveFixtures.url("corrupt-payload.zip")
    let snapshot = try Archive.snapshot(at: url)
    let entry = try #require(snapshot.entries.first)
    let source = try ArchiveFileContentSource(url: url, fingerprint: snapshot.fingerprint, entry: entry)
    await #expect(throws: ArchiveError.self) { try await source.read(at: 0, count: 100) }
}

@Test func sourceLifetimeReleasesSpillOwner() async throws {
    var source: ArchiveFileContentSource? = try archiveSource()
    weak var owner = source
    _ = try await source?.read(at: 0, count: 1)
    #expect(await source?.usesDisk == true)
    source = nil
    #expect(owner == nil)
}

@Test func archiveFileSystemOpensLiteralSpecialNames() async throws {
    let fs = try ArchiveFileSystem(url: ArchiveFixtures.url("tree.zip"))
    let path = FileSystemPath(fs.root.url.appendingPathComponent("space % # ü.txt"))
    #expect(fs.canViewFile(at: path))
    let source = try await fs.openFile(at: path)
    #expect(try await source.read(at: 0, count: 10) == Data("hello".utf8))
}

@Test func cancellationPreservesPreviouslyMaterializedData() async throws {
    let source = try archiveSource()
    let first = try await source.read(at: 0, count: 17)
    let prepared = await source.materializedBytes
    let request = Task {
        while !Task.isCancelled { await Task.yield() }
        return try await source.read(at: 200_000, count: 20)
    }
    request.cancel()
    do { _ = try await request.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    #expect(await source.materializedBytes == prepared)
    #expect(try await source.read(at: 0, count: 17) == first)
    #expect(try await source.read(at: 200_000, count: 20).count == 20)
}
