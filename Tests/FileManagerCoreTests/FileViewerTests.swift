import Foundation
import Testing
@testable import FileManagerCore

private func viewerFixture(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
}

@Test func viewerScrollsBothDirectionsAndHandlesLineEndings() async throws {
    let url = try viewerFixture(Data("one\r\n\ntwo\nlast".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    #expect(try await document.page(rows: 2).lines.map(\.text) == ["one", ""])
    #expect(try await document.page(.scroll(1), rows: 2).lines.map(\.text) == ["", "two"])
    #expect(try await document.page(.scroll(-1), rows: 1).lines.map(\.text) == ["one"])
    #expect(try await document.page(.end, rows: 2).lines.map(\.text) == ["two", "last"])
    #expect(try await document.page(.home, rows: 1).offset == 0)
}

@Test func viewerWrapsLongLinesAtVisibleWidthAndScrollsByWrappedRows() async throws {
    let url = try viewerFixture(Data("abcdefghij\nnext".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)

    let first = try await document.page(rows: 3, wrapColumns: 4)
    #expect(first.lines.map(\.text) == ["abcd", "efgh", "ij"])

    let down = try await document.page(.scroll(1), rows: 3, wrapColumns: 4)
    #expect(down.lines.map(\.text) == ["efgh", "ij", "next"])

    let back = try await document.page(.scroll(-1), rows: 3, wrapColumns: 4)
    #expect(back.lines.map(\.text) == first.lines.map(\.text))

    let end = try await document.page(.end, rows: 2, wrapColumns: 4)
    #expect(end.lines.map(\.text) == ["ij", "next"])
}

@Test func unwrappedViewerPreservesLongLogicalLines() async throws {
    let long = String(repeating: "x", count: 12_000)
    let url = try viewerFixture(Data((long + "\nnext").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)

    let page = try await document.page(rows: 2)
    #expect(page.lines.count == 2)
    #expect(page.lines[0].text == long)
    #expect(page.lines[1].text == "next")

    let end = try await document.page(.end, rows: 2)
    #expect(end.lines[0].text == long)
    #expect(end.lines[1].text == "next")
}

@Test func viewerDoesNotSplitUTF8OrCRLFAcrossArtificialRows() async throws {
    for suffix in ["😀Z\nlast", "\r\nlast"] {
        let content = String(repeating: "a", count: 4095) + suffix
        let url = try viewerFixture(Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FileViewerDocument(url: url)
        let first = try await document.page(rows: 1)
        #expect(!first.lines[0].text.contains("�"))
        let second = try await document.page(.scroll(1), rows: 1)
        #expect(!second.lines[0].text.contains("�"))
        let back = try await document.page(.scroll(-1), rows: 1)
        #expect(back.offset == first.offset)
        #expect(back.lines[0].text == first.lines[0].text)
    }
}

@Test func viewerOpensAndJumpsToEndOfLargeSparseFileWithBoundedReads() async throws {
    let url = try viewerFixture(Data("header\n".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let size: UInt64 = 8 * 1024 * 1024 * 1024
    let tail = Data("\nlast-line\n".utf8)
    try handle.truncate(atOffset: size)
    try handle.seek(toOffset: size - UInt64(tail.count))
    try handle.write(contentsOf: tail)
    let document = try FileViewerDocument(url: url)
    let first = try await document.page(rows: 1)
    #expect(first.lines[0].text == "header")
    let end = try await document.page(.end, rows: 4, wrapColumns: 80)
    #expect(end.fileSize == Int64(size))
    #expect(end.lines.last?.text == "last-line")
    #expect(await document.bytesRead < 1_048_576)
    #expect(end.lines.count <= 4)
    #expect(end.lines.allSatisfy { $0.text.utf8.count <= 4096 * 4 })
}

@Test func viewerHandlesEmptyInvalidUTF8AndTruncation() async throws {
    let url = try viewerFixture(Data())
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    #expect(try await document.page(.end, rows: 20).lines.isEmpty)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data([0xFF, 0x00, 0x0A]) + Data("next\n".utf8))
    let grown = try await document.page(.home, rows: 5)
    #expect(grown.lines.map(\.text) == ["�·", "next"])
    _ = try await document.page(.end, rows: 1)
    try handle.truncate(atOffset: 0)
    let empty = try await document.page(rows: 10)
    #expect(empty.fileSize == 0)
    #expect(empty.offset == 0)
    #expect(empty.lines.isEmpty)
}

@Test func viewerRejectsNonRegularFiles() {
    #expect(throws: FileViewerError.self) { _ = try FileViewerDocument(url: URL(fileURLWithPath: "/dev/null")) }
}

@Test func viewerDoesNotInventEmptyRowsAtSegmentBoundary() async throws {
    let url = try viewerFixture(Data((String(repeating: "x", count: 4096) + "\nnext").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 3)
    #expect(page.lines.count == 2)
    #expect(page.lines.last?.text == "next")
    _ = try await document.page(.scroll(1), rows: 1)
    #expect(try await document.page(.scroll(-1), rows: 1).offset == 0)
}

@Test func hexShowsAllByteValuesAndAlignsPartialRows() async throws {
    let url = try viewerFixture(Data((0...255).map(UInt8.init)) + Data([0x41]))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let first = try await document.page(rows: 2, mode: .hex)
    #expect(first.mode == .hex)
    #expect(first.lines[0].text.hasPrefix("0000000000000000: 00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F"))
    #expect(first.lines[0].text.hasSuffix("................"))
    let last = try await document.page(.end, rows: 1, mode: .hex)
    #expect(last.offset == 256)
    #expect(last.endOffset == 257)
    #expect(last.lines[0].text == HexRowFormatter.format(offset: 256, bytes: [0x41]))
    #expect(last.lines[0].text.count == 69)
    let previous = try await document.page(.scroll(-1), rows: 1, mode: .hex)
    #expect(previous.offset == 240)
    #expect(previous.lines[0].text.contains("F0 F1 F2 F3"))
}

@Test func viewerTogglesModesNearSamePositionAndRestoresExactTextRow() async throws {
    let url = try viewerFixture(Data("first line\nsecond line\nthird line".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let text = try await document.page(.scroll(1), rows: 1)
    #expect(text.offset == 11)
    let hex = try await document.page(rows: 1, mode: .hex)
    #expect(hex.offset == 0)
    let restored = try await document.page(rows: 1, mode: .text)
    #expect(restored.offset == text.offset)
    #expect(restored.lines[0].text == "second line")
    _ = try await document.page(.end, rows: 1, mode: .hex)
    let moved = try await document.page(rows: 1, mode: .text)
    #expect(moved.lines[0].text == "third line")
}

@Test func hexHandlesEmptyTruncatedAndLargeSparseFiles() async throws {
    let url = try viewerFixture(Data())
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    #expect(try await document.page(.end, rows: 5, mode: .hex).lines.isEmpty)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let size: UInt64 = 8 * 1024 * 1024 * 1024
    try handle.truncate(atOffset: size)
    let last = try await document.page(.end, rows: 2, mode: .hex)
    #expect(last.offset == Int64(size - 32))
    #expect(last.lines[0].text.hasPrefix("00000001FFFFFFE0:"))
    #expect(await document.bytesRead <= 65_536)
    try handle.truncate(atOffset: 1)
    let truncated = try await document.page(rows: 2, mode: .hex)
    #expect(truncated.offset == 0)
    #expect(truncated.endOffset == 1)
    #expect(truncated.lines.count == 1)
}

@Test func viewerFollowsAbsoluteRelativeAndChainedSymlinks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("file.txt")
    try Data("linked contents".utf8).write(to: file)
    let targets = ["absolute": file.path, "relative": "file.txt", "chain": "relative"]
    for (name, target) in targets {
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent(name).path, withDestinationPath: target)
    }
    for name in targets.keys {
        let document = try FileViewerDocument(url: directory.appendingPathComponent(name))
        #expect(try await document.page(rows: 1).lines.first?.text == "linked contents")
    }
}

@Test func viewerReportsBrokenAndLoopingSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, target) in ["broken": "missing.txt", "loop": "loop"] {
        let link = directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        do {
            _ = try FileViewerDocument(url: link)
            Issue.record("Unavailable symlink should fail")
        } catch FileViewerError.symbolicLinkUnavailable(let path, let reportedTarget, _) {
            #expect(path == link.path)
            #expect(reportedTarget == target)
        }
    }
}
