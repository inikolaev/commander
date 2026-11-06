import Foundation
import Testing
@testable import FileManagerCore

private func withCopyFixture(_ body: (URL, URL) throws -> Void) throws {
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.txt")
    try Data("original contents".utf8).write(to: source)
    try body(folder, source)
}

@Test func copyPreservesSourceAndProducesCompleteDestination() throws {
    try withCopyFixture { (folder: URL, source: URL) throws -> Void in
        let destination = folder.appendingPathComponent("copy with spaces.txt")
        try LocalFileCopier().copyFile(from: source, to: destination)
        #expect(try Data(contentsOf: source) == Data(contentsOf: destination))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["copy with spaces.txt", "source.txt"])
    }
}

@Test func copyDoesNotOverwriteExistingFileOrSource() throws {
    try withCopyFixture { (folder: URL, source: URL) throws -> Void in
        let destination = folder.appendingPathComponent("existing.txt")
        try Data("keep me".utf8).write(to: destination)
        #expect(throws: FileCopyError.self) { try LocalFileCopier().copyFile(from: source, to: destination) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep me")
        #expect(throws: FileCopyError.self) { try LocalFileCopier().copyFile(from: source, to: source) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original contents")
    }
}

@Test func copyRejectsMissingDestinationFolder() throws {
    try withCopyFixture { (folder: URL, source: URL) throws -> Void in
        #expect(throws: (any Error).self) { try LocalFileCopier().copyFile(from: source, to: folder.appendingPathComponent("missing/file")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["source.txt"])
    }
}

@Test func copyDirectoryRecursivelyPreservesContentsLinksAndMetadata() throws {
    try withCopyFixture { folder, source in
        let manager = FileManager.default
        let directory = folder.appendingPathComponent("tree")
        let nested = directory.appendingPathComponent("nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2 * 1024 * 1024).write(to: nested.appendingPathComponent("data"))
        try manager.createDirectory(at: directory.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try manager.createSymbolicLink(atPath: directory.appendingPathComponent("relative-link").path, withDestinationPath: "nested/data")
        try manager.createSymbolicLink(atPath: directory.appendingPathComponent("directory-link").path, withDestinationPath: "nested")
        try manager.createSymbolicLink(atPath: directory.appendingPathComponent("dangling").path, withDestinationPath: "missing")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try manager.setAttributes([.modificationDate: modified], ofItemAtPath: nested.path)
        try manager.setAttributes([.posixPermissions: 0o751, .modificationDate: modified], ofItemAtPath: directory.path)
        let destination = folder.appendingPathComponent("tree copy")
        let capture = ProgressCapture()
        try LocalFileCopier().copyFile(from: directory, to: destination,
            progress: { capture.record($0) }, isCancelled: { false })
        #expect(try Data(contentsOf: nested.appendingPathComponent("data")) == Data(contentsOf: destination.appendingPathComponent("nested/data")))
        #expect(try manager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("relative-link").path) == "nested/data")
        #expect(try manager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("directory-link").path) == "nested")
        #expect(try manager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dangling").path) == "missing")
        #expect(try manager.contentsOfDirectory(atPath: destination.appendingPathComponent("empty").path).isEmpty)
        #expect((try manager.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o751)
        let copiedDate = try manager.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date
        #expect(copiedDate == modified)
        #expect((try manager.attributesOfItem(atPath: destination.appendingPathComponent("nested").path)[.modificationDate] as? Date) == modified)
        #expect(capture.samples.last?.copiedBytes == Int64(2 * 1024 * 1024))
        #expect(capture.samples.allSatisfy { $0.totalBytes == Int64(2 * 1024 * 1024) })
        #expect(try Data(contentsOf: source) == Data("original contents".utf8))
    }
}

@Test func copyDirectoryRejectsDescendantAndExistingDestination() throws {
    try withCopyFixture { folder, _ in
        let manager = FileManager.default
        let directory = folder.appendingPathComponent("tree")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let alias = folder.appendingPathComponent("alias")
        try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: "tree")
        #expect(throws: FileCopyError.self) {
            try LocalFileCopier().copyFile(from: directory, to: directory.appendingPathComponent("child"))
        }
        #expect(throws: FileCopyError.self) {
            try LocalFileCopier().copyFile(from: directory, to: alias.appendingPathComponent("child"))
        }
        let existing = folder.appendingPathComponent("existing")
        try manager.createSymbolicLink(atPath: existing.path, withDestinationPath: "missing")
        #expect(throws: FileCopyError.self) {
            try LocalFileCopier().copyFile(from: directory, to: existing)
        }
        #expect(try manager.destinationOfSymbolicLink(atPath: existing.path) == "missing")
        #expect(try manager.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

@Test func copyDirectoryRejectsDescendantWithDifferentSourceCase() throws {
    try withCopyFixture { folder, _ in
        let manager = FileManager.default
        let actual = folder.appendingPathComponent("Tree")
        let alternateCase = folder.appendingPathComponent("tree")
        try manager.createDirectory(at: actual, withIntermediateDirectories: false)
        // This alias exists only on case-insensitive volumes.
        guard manager.fileExists(atPath: alternateCase.path) else { return }
        #expect(throws: FileCopyError.self) {
            try LocalFileCopier().copyFile(from: alternateCase, to: actual.appendingPathComponent("child"))
        }
        let alias = folder.appendingPathComponent("alias")
        try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: "Tree")
        #expect(throws: FileCopyError.self) {
            try LocalFileCopier().copyFile(from: alternateCase, to: alias.appendingPathComponent("child"))
        }
        #expect(try manager.contentsOfDirectory(atPath: actual.path).isEmpty)
        #expect(try manager.contentsOfDirectory(atPath: folder.path).sorted() == ["Tree", "alias", "source.txt"])
    }
}

@Test func cancellingDirectoryCopyRemovesPartialTree() throws {
    try withCopyFixture { folder, _ in
        let manager = FileManager.default
        let directory = folder.appendingPathComponent("tree")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(repeating: 3, count: 8 * 1024 * 1024).write(to: directory.appendingPathComponent("large"))
        let destination = folder.appendingPathComponent("copy")
        let token = CopyCancellation()
        #expect(throws: CancellationError.self) {
            try LocalFileCopier().copyFile(from: directory, to: destination,
                progress: { if $0.copiedBytes > 0 { token.cancel() } }, isCancelled: { token.isCancelled })
        }
        #expect(!manager.fileExists(atPath: destination.path))
        #expect(try manager.contentsOfDirectory(atPath: folder.path).sorted() == ["source.txt", "tree"])
    }
}

@Test func destinationCreatedDuringDirectoryCopyIsNotOverwritten() throws {
    try withCopyFixture { folder, _ in
        let manager = FileManager.default
        let directory = folder.appendingPathComponent("tree")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        let nested = directory.appendingPathComponent("nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data(repeating: 9, count: 2 * 1024 * 1024).write(to: nested.appendingPathComponent("large"))
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: nested.path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
        }
        let destination = folder.appendingPathComponent("copy")
        let collision = DestinationCollision(destination: destination)
        #expect(throws: (any Error).self) {
            try LocalFileCopier().copyFile(from: directory, to: destination,
                progress: { value in if value.copiedBytes > 0 { collision.create() } }, isCancelled: { false })
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
        #expect(try manager.contentsOfDirectory(atPath: folder.path).sorted() == ["copy", "source.txt", "tree"])
    }
}

@Test func copyLockedDirectoryPreservesLockAndCleansStagingOnCollision() throws {
    try withCopyFixture { folder, _ in
        let manager = FileManager.default
        let directory = folder.appendingPathComponent("locked")
        let destination = folder.appendingPathComponent("copy")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(repeating: 8, count: 2 * 1024 * 1024).write(to: directory.appendingPathComponent("data"))
        try manager.setAttributes([.immutable: true], ofItemAtPath: directory.path)
        defer {
            try? manager.setAttributes([.immutable: false], ofItemAtPath: directory.path)
            try? manager.setAttributes([.immutable: false], ofItemAtPath: destination.path)
        }
        try LocalFileCopier().copyFile(from: directory, to: destination)
        #expect((try manager.attributesOfItem(atPath: destination.path)[.immutable] as? NSNumber)?.boolValue == true)
        #expect(try Data(contentsOf: destination.appendingPathComponent("data")) == Data(contentsOf: directory.appendingPathComponent("data")))
        try manager.setAttributes([.immutable: false], ofItemAtPath: destination.path)
        try manager.removeItem(at: destination)
        let collision = DestinationCollision(destination: destination)
        #expect(throws: (any Error).self) {
            try LocalFileCopier().copyFile(from: directory, to: destination,
                progress: { value in if value.copiedBytes > 0 { collision.create() } }, isCancelled: { false })
        }
        #expect(try manager.contentsOfDirectory(atPath: folder.path).sorted() == ["copy", "locked", "source.txt"])
    }
}

private final class DestinationCollision: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private var created = false
    init(destination: URL) { self.destination = destination }
    func create() {
        lock.withLock {
            guard !created else { return }
            created = true
            try? Data("keep".utf8).write(to: destination)
        }
    }
}

@Test func copyPreservesSymlinksAndProtectsDanglingDestination() throws {
    try withCopyFixture { (folder: URL, source: URL) throws -> Void in
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "source.txt")
        let copy = folder.appendingPathComponent("copied-link")
        try LocalFileCopier().copyFile(from: link, to: copy)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.path) == "source.txt")
        let dangling = folder.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing")
        #expect(throws: FileCopyError.self) { try LocalFileCopier().copyFile(from: source, to: dangling) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == "missing")
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CopyProgress] = []
    func record(_ value: CopyProgress) { lock.withLock { values.append(value) } }
    var samples: [CopyProgress] { lock.withLock { values } }
}

@Test func copyReportsBytesAndPreservesPermissionsAndDate() throws {
    try withCopyFixture { (folder: URL, source: URL) throws -> Void in
        let contents = Data(repeating: 42, count: 4 * 1024 * 1024)
        try contents.write(to: source)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o751, .modificationDate: modified], ofItemAtPath: source.path)
        let capture = ProgressCapture()
        let destination = folder.appendingPathComponent("copy")
        try LocalFileCopier().copyFile(from: source, to: destination,
            progress: { capture.record($0) }, isCancelled: { false })
        #expect(capture.samples.first?.copiedBytes == 0)
        #expect(capture.samples.last?.copiedBytes == Int64(contents.count))
        #expect(capture.samples.allSatisfy { $0.totalBytes == Int64(contents.count) })
        #expect(try Data(contentsOf: destination) == contents)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o751)
        #expect(attributes[.modificationDate] as? Date == modified)
    }
}

@Test func cancellationDuringCopyRemovesStagingAndLeavesSourceUntouched() throws {
    try withCopyFixture { (folder: URL, source: URL) throws -> Void in
        let contents = Data(repeating: 17, count: 8 * 1024 * 1024)
        try contents.write(to: source)
        let destination = folder.appendingPathComponent("copy")
        let token = CopyCancellation()
        #expect(throws: CancellationError.self) {
            try LocalFileCopier().copyFile(from: source, to: destination, progress: {
                if $0.copiedBytes > 0 { token.cancel() }
            }, isCancelled: { token.isCancelled })
        }
        #expect(token.isCancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["source.txt"])
        #expect(try Data(contentsOf: source) == contents)
    }
}

@Test func zeroByteFileCompletesAndPreCancelledCopyWritesNothing() throws {
    try withCopyFixture { (folder: URL, source: URL) throws -> Void in
        try Data().write(to: source)
        let destination = folder.appendingPathComponent("empty")
        try LocalFileCopier().copyFile(from: source, to: destination)
        #expect(try Data(contentsOf: destination).isEmpty)
        #expect(throws: CancellationError.self) {
            try LocalFileCopier().copyFile(from: source, to: folder.appendingPathComponent("cancelled"),
                progress: { _ in }, isCancelled: { true })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["empty", "source.txt"])
    }
}
