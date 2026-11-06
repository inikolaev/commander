import Foundation
import Testing
@testable import FileManagerCore

@Test func batchCopiesFilesAndStopsOnCollisionWithoutOverwriting() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = root.appendingPathComponent("target")
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let sources = ["one", "two", "three"].map { root.appendingPathComponent($0) }
    for source in sources { try Data(source.lastPathComponent.utf8).write(to: source) }
    try Data("existing".utf8).write(to: target.appendingPathComponent("two"))
    #expect(throws: (any Error).self) {
        try FileCopyBatch(sources: sources, destination: target).run(using: LocalFileCopier(), progress: { _ in }, isCancelled: { false })
    }
    #expect(try String(contentsOf: target.appendingPathComponent("one"), encoding: .utf8) == "one")
    #expect(try String(contentsOf: target.appendingPathComponent("two"), encoding: .utf8) == "existing")
    #expect(!manager.fileExists(atPath: target.appendingPathComponent("three").path))
    try manager.removeItem(at: target)
    try manager.createDirectory(at: target, withIntermediateDirectories: false)
    _ = try FileCopyBatch(sources: sources, destination: target).run(using: LocalFileCopier(), progress: { _ in }, isCancelled: { false })
    for source in sources {
        #expect(try Data(contentsOf: source) == Data(contentsOf: target.appendingPathComponent(source.lastPathComponent)))
    }
}

@Test func cancelledBatchDoesNotStartCopying() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = ["one", "two"].map { root.appendingPathComponent($0) }
    for source in sources { try Data().write(to: source) }
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    #expect(throws: CancellationError.self) {
        try FileCopyBatch(sources: sources, destination: target).run(using: LocalFileCopier(), progress: { _ in }, isCancelled: { true })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
}

@Test func batchCopiesMixedFilesAndDirectoriesWithCombinedProgress() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let target = root.appendingPathComponent("target")
    let directory = root.appendingPathComponent("folder")
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: root) }
    let file = root.appendingPathComponent("file")
    try Data(repeating: 1, count: 1000).write(to: file)
    try Data(repeating: 2, count: 2000).write(to: directory.appendingPathComponent("nested"))
    let progress = BatchProgressCapture()
    _ = try FileCopyBatch(sources: [file, directory], destination: target).run(using: LocalFileCopier(),
        progress: { progress.record($0) }, isCancelled: { false })
    #expect(try Data(contentsOf: target.appendingPathComponent("file")) == Data(contentsOf: file))
    #expect(try Data(contentsOf: target.appendingPathComponent("folder/nested")) == Data(contentsOf: directory.appendingPathComponent("nested")))
    #expect(progress.samples.last?.copiedBytes == 3000)
    #expect(progress.samples.allSatisfy { $0.totalBytes == 3000 })
}

private final class BatchProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CopyProgress] = []
    func record(_ value: CopyProgress) { lock.withLock { values.append(value) } }
    var samples: [CopyProgress] { lock.withLock { values } }
}
