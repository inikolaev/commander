import Foundation
import Testing
@testable import FileManagerCore

private actor DelayedContentSource: FileContentSource {
    let data = Data("first\nsecond\nthird\n".utf8)
    var started = false
    var knownSize = false
    var delay = true
    func metadata() -> ContentMetadata { ContentMetadata(size: knownSize ? Int64(data.count) : nil) }
    func length() -> Int64 { knownSize = true; return Int64(data.count) }
    func read(at offset: Int64, count: Int) async throws -> Data {
        started = true
        if delay { try await Task.sleep(for: .milliseconds(100)); delay = false }
        let start = min(data.count, Int(offset))
        let end = min(data.count, start + count)
        if end == data.count { knownSize = true }
        return data.subdata(in: start..<end)
    }
}

@Test @MainActor func slowSourceDoesNotBlockUIAndCancelledPageDoesNotCommitNavigation() async throws {
    let source = DelayedContentSource()
    let document = FileViewerDocument(source: source)
    let cancelled = Task { try await document.page(.scroll(1), rows: 1) }
    while !(await source.started) { await Task.yield() }
    // This main-actor continuation runs while the read is pending.
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("Expected cancellation") }
    catch is CancellationError {}
    #expect(try await document.page(rows: 1).lines.first?.text == "first")
    #expect(try await document.page(.end, rows: 1).lines.first?.text == "third")
}

@Test func overlappingPageRequestsPreserveSequentialNavigation() async throws {
    let source = DelayedContentSource()
    let document = FileViewerDocument(source: source)
    let first = Task { try await document.page(.scroll(1), rows: 1) }
    while !(await source.started) { await Task.yield() }
    let second = Task { try await document.page(.scroll(1), rows: 1) }
    #expect(try await first.value.lines.first?.text == "second")
    #expect(try await second.value.lines.first?.text == "third")
}

@Test func localContentRangesAndCacheAreSourceOwned() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let contents = Data((0..<100).map { UInt8($0) })
    try contents.write(to: url)
    let source = try LocalFileContentSource(url: url, bufferSize: 16)
    #expect(try await source.read(at: 14, count: 10) == contents.subdata(in: 14..<24))
    #expect(await source.bytesRead == 32)
    #expect(try await source.read(at: 18, count: 3) == contents.subdata(in: 18..<21))
    #expect(await source.bytesRead == 32)
    #expect(try await source.read(at: 98, count: 10) == contents.suffix(2))
    #expect(try await source.read(at: 200, count: 10).isEmpty)
    #expect(try await source.read(at: 0, count: 0).isEmpty)
    await #expect(throws: ContentSourceError.self) { try await source.read(at: -1, count: 1) }
    await #expect(throws: ContentSourceError.self) { try await source.read(at: Int64.max, count: 1) }
}

@Test func unknownSizeHexJumpFindsActualEnd() async throws {
    let source = DelayedContentSource()
    let document = FileViewerDocument(source: source)
    let page = try await document.page(.scroll(200), rows: 1, mode: .hex)
    #expect(page.fileSize == 19)
    #expect(page.offset == 16)
    #expect(page.endOffset == 19)
}

@Test func wrappedInvalidUTF8KeepsOriginalByteOffsets() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0xff, 0x61, 0x62, 0x63]).write(to: url)
    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 4, wrapColumns: 1)
    #expect(page.lines.map(\.text) == ["�", "a", "b", "c"])
    #expect(page.lines.map(\.offset) == [0, 1, 2, 3])
    #expect(page.endOffset == 4)
}

@Test func oversizedLogicalLineSuggestsWrappedViewing() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 65, count: 16 * 1024 * 1024 + 1).write(to: url)
    let document = try FileViewerDocument(url: url)
    await #expect(throws: FileViewerError.self) { try await document.page(rows: 1) }
    #expect(try await document.page(rows: 1, wrapColumns: 80).lines.first?.text.count == 80)
}
