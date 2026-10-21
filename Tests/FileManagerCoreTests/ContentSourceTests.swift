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

private actor PausedWrappedContentSource: FileContentSource {
    let data = Data(repeating: 120, count: 20_000)
    private var shouldPause = true
    private var entered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    func metadata() -> ContentMetadata { ContentMetadata(size: Int64(data.count), revision: 0) }
    func length() -> Int64 { Int64(data.count) }
    func hasEnteredPause() -> Bool { entered }
    func release() {
        shouldPause = false
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
    func read(at offset: Int64, count: Int) async throws -> Data {
        if offset == 5000 && shouldPause {
            entered = true
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        let start = min(data.count, Int(offset))
        return data.subdata(in: start..<min(data.count, start + count))
    }
}

private actor CountingContentSource: FileContentSource {
    let data: Data
    private(set) var largestRequest = 0
    private(set) var readCalls = 0
    init(_ data: Data = Data(repeating: 120, count: 120_000)) { self.data = data }
    func metadata() -> ContentMetadata { ContentMetadata(size: Int64(data.count), revision: 0) }
    func length() -> Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) -> Data {
        readCalls += 1
        largestRequest = max(largestRequest, count)
        let start = min(data.count, Int(offset))
        return data.subdata(in: start..<min(data.count, start + count))
    }
}

private actor UnknownRevisionContentSource: FileContentSource {
    let data: Data
    private var knownSize = false
    private var pauseEndRead = false
    private var endReadEntered = false
    private var releaseEndRead: CheckedContinuation<Void, Never>?
    init(_ data: Data) { self.data = data }
    func metadata() -> ContentMetadata { ContentMetadata(size: knownSize ? Int64(data.count) : nil, revision: 0) }
    func length() -> Int64 { knownSize = true; return Int64(data.count) }
    func revealSize() { knownSize = true }
    func holdEndRead() { pauseEndRead = true }
    func enteredEndRead() -> Bool { endReadEntered }
    func releaseHeldEndRead() {
        pauseEndRead = false
        releaseEndRead?.resume()
        releaseEndRead = nil
    }
    func read(at offset: Int64, count: Int) async -> Data {
        if pauseEndRead && offset == Int64(data.count - 1) {
            endReadEntered = true
            await withCheckedContinuation { releaseEndRead = $0 }
        }
        let start = min(data.count, Int(offset))
        return data.subdata(in: start..<min(data.count, start + count))
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

@Test func wrappedReadCancellationRestoresPosition() async throws {
    let source = PausedWrappedContentSource()
    let document = FileViewerDocument(source: source)
    let pending = Task { try await document.page(.scroll(1), rows: 1, wrapColumns: 5000) }
    while !(await source.hasEnteredPause()) { await Task.yield() }
    pending.cancel()
    await source.release()
    do { _ = try await pending.value; Issue.record("Expected cancellation") }
    catch is CancellationError {}
    #expect(try await document.page(rows: 1, wrapColumns: 5000).offset == 0)
}

@Test func viewerWrappedSourceRequestsRemainBounded() async throws {
    let source = CountingContentSource()
    let document = FileViewerDocument(source: source)
    let page = try await document.page(.end, rows: 3, wrapColumns: 5000)
    #expect(page.endOffset == 120_000)
    #expect(await source.largestRequest <= 4096)
}

@Test func viewerWrappedColdEndShortLinesUsesBoundedWork() async throws {
    let source = CountingContentSource(Data(String(repeating: "row\n", count: 1000).utf8))
    let document = FileViewerDocument(source: source)
    let page = try await document.page(.end, rows: 200, wrapColumns: 80)
    #expect(page.lines.count == 200)
    #expect(page.lines.allSatisfy { $0.text == "row" })
    #expect(page.endOffset == 4000)
    #expect(await source.readCalls < 2000)
}

@Test func viewerUnknownSizeResolutionKeepsTextHistory() async throws {
    let source = UnknownRevisionContentSource(Data(repeating: 120, count: 120_003))
    let document = FileViewerDocument(source: source)
    let end = try await document.page(.end, rows: 3, wrapColumns: 80)
    #expect(end.lines.count == 3)
    #expect(try await document.page(rows: 3, wrapColumns: 80).offset == end.offset)
    let previous = try await document.page(.scroll(-1), rows: 1, wrapColumns: 80)
    #expect(previous.offset < end.offset)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 80).offset == end.offset)

    let ordinary = FileViewerDocument(source: UnknownRevisionContentSource(Data("abc\nlast".utf8)))
    let moved = try await ordinary.page(.scroll(1), rows: 1, wrapColumns: 80)
    #expect(moved.offset == 4)
    #expect(moved.fileSize == 8)
    #expect(try await ordinary.page(rows: 1, wrapColumns: 80).offset == 4)
    #expect(try await ordinary.page(.scroll(-1), rows: 1, wrapColumns: 80).offset == 0)
}

@Test func viewerUnknownToKnownSizeKeepsPositionAfterCancelledEnd() async throws {
    let source = UnknownRevisionContentSource(Data(repeating: 120, count: 120_003))
    let document = FileViewerDocument(source: source)
    _ = try await document.page(.home, rows: 1, wrapColumns: 80)
    var page = try await document.page(rows: 1, wrapColumns: 80)
    for _ in 0..<5 { page = try await document.page(.scroll(200), rows: 1, wrapColumns: 80) }
    #expect(page.offset == 80_000)
    #expect(page.fileSize == nil)
    await source.holdEndRead()
    let pending = Task { try await document.page(.end, rows: 1, wrapColumns: 80) }
    while !(await source.enteredEndRead()) { await Task.yield() }
    pending.cancel()
    await source.releaseHeldEndRead()
    do { _ = try await pending.value; Issue.record("Expected cancellation") }
    catch is CancellationError {}
    #expect(try await document.page(rows: 1, wrapColumns: 80).offset == 80_000)
    #expect(try await document.page(.scroll(-1), rows: 1, wrapColumns: 80).offset == 79_920)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 80).offset == 80_000)
}

@Test func viewerUnknownToKnownSizeKeepsSavedHexPosition() async throws {
    let source = UnknownRevisionContentSource(Data(repeating: 120, count: 120_003))
    let document = FileViewerDocument(source: source)
    _ = try await document.page(.home, rows: 1, wrapColumns: 80)
    for _ in 0..<5 { _ = try await document.page(.scroll(200), rows: 1, wrapColumns: 80) }
    #expect(try await document.page(rows: 1, wrapColumns: 80).offset == 80_000)
    _ = try await document.page(rows: 1, mode: .hex)
    await source.revealSize()
    #expect(try await document.page(rows: 1, wrapColumns: 80).offset == 80_000)
    #expect(try await document.page(.scroll(-1), rows: 1, wrapColumns: 80).offset == 79_920)
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
    await #expect(throws: FileViewerError.self) { try await document.page(rows: 1, wrapColumns: Int.max) }
    let small = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: small) }
    try Data("short".utf8).write(to: small)
    #expect(try await FileViewerDocument(url: small).page(rows: 1, wrapColumns: Int.max).lines[0].text == "short")
}

@Test func localContentRevisionTracksSameSizeEdits() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("first".utf8).write(to: url)
    let source = try LocalFileContentSource(url: url)
    let original = try await source.metadata().revision
    #expect(original != nil)
    #expect(try await source.metadata().revision == original)
    try Data("other".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
    let changed = try await source.metadata().revision
    #expect(changed != original)
    #expect(try await source.read(at: 0, count: 5) == Data("other".utf8))
}

@Test func viewerWrappedRevisionChangeRecoversTop() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("abcdEFGH\nnext\n".utf8).write(to: url)
    let document = try FileViewerDocument(url: url)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 4).offset == 4)
    try Data("ab\nDEFGH\nnext\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
    let recovered = try await document.page(rows: 1, wrapColumns: 4)
    #expect(recovered.offset == 3)
    #expect(recovered.lines[0].text == "DEFG")
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 4).offset == 7)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 4).offset == 9)
    #expect(try await document.page(.scroll(-1), rows: 1, wrapColumns: 4).offset == 7)
    #expect(try await document.page(.scroll(-1), rows: 1, wrapColumns: 4).offset == 3)

    _ = try await document.page(.scroll(1), rows: 1, wrapColumns: 4)
    _ = try await document.page(rows: 1, mode: .hex)
    try Data("abcdEFGH\nnext\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: url.path)
    let fromHex = try await document.page(rows: 1, wrapColumns: 4)
    #expect(fromHex.offset == 4)
    #expect(fromHex.lines[0].text == "EFGH")

    _ = try await document.page(.scroll(1), rows: 1, wrapColumns: 4)
    _ = try await document.page(rows: 1, mode: .hex)
    try Data("ab\nDEFGH\nnext\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3000)], ofItemAtPath: url.path)
    let next = try await document.page(rows: 1, wrapColumns: 4)
    #expect(next.offset == 9)
    #expect(next.lines[0].text == "next")

    // A saved wrapped byte must be recovered even though its aligned hex row is zero.
    try Data("abcdEFGH\nnext\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 4000)], ofItemAtPath: url.path)
    let savedDocument = try FileViewerDocument(url: url)
    #expect(try await savedDocument.page(.scroll(1), rows: 1, wrapColumns: 4).offset == 4)
    _ = try await savedDocument.page(rows: 1, mode: .hex)
    try Data("ab\nDEFGH\nnext\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5000)], ofItemAtPath: url.path)
    let savedRecovery = try await savedDocument.page(rows: 1, wrapColumns: 4)
    #expect(savedRecovery.offset == 3)
    #expect(savedRecovery.lines[0].text == "DEFG")
}

@Test func viewerWrappedInvalidUTF8PreservesOffsets() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try (Data(repeating: 97, count: 4095) + Data([0xE1, 0x80, 0x41, 0x0A]) + Data("tail".utf8)).write(to: url)
    let page = try await FileViewerDocument(url: url).page(rows: 2, wrapColumns: 5000)
    #expect(page.lines[0].text.hasSuffix("�A"))
    #expect(page.lines[0].endOffset == 4098)
    #expect(page.lines[1].offset == 4099)
    #expect(page.lines[1].text == "tail")
}

@Test func viewerWrappedRowsMatchAcrossLocalCacheSizes() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("é\tabc\r\n😀xyz\nlast".utf8).write(to: url)
    var snapshots: [[String]] = []
    var offsets: [[Int64]] = []
    for cacheSize in [16, 64, 65_536] {
        let source = try LocalFileContentSource(url: url, bufferSize: cacheSize)
        let page = try await FileViewerDocument(source: source).page(rows: 10, wrapColumns: 4, includeSourceText: true)
        snapshots.append(page.lines.map { [$0.text, $0.sourceText ?? ""] }.flatMap { $0 })
        offsets.append(page.lines.flatMap { [$0.offset, $0.endOffset] })
    }
    #expect(snapshots[0] == snapshots[1] && snapshots[1] == snapshots[2])
    #expect(offsets[0] == offsets[1] && offsets[1] == offsets[2])
}
