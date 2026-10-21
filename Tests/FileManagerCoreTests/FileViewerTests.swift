import Foundation
import Testing
@testable import FileManagerCore

private func viewerFixture(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
}

@Test func viewerWrappedShortLineCrossesReadBoundaries() async throws {
    let line = "          const index = +e.target.dataset.index;"
    for boundary in [4096, 8192, 65_536] {
        let start = boundary - 13
        let data = Data((String(repeating: "x", count: start - 1) + "\n" + line + "\nnext\n").utf8)
        let url = try viewerFixture(data)
        defer { try? FileManager.default.removeItem(at: url) }
        for columns in [80, 120, 200] {
            let document = try FileViewerDocument(url: url)
            let page = try await document.page(.end, rows: 2, wrapColumns: columns, includeSourceText: true)
            #expect(page.lines.map(\.text) == [line, "next"])
            #expect(page.lines.map(\.sourceText) == [line, "next"])
            #expect(page.lines.map(\.offset) == [Int64(start), Int64(start + 49)])
            #expect(page.lines.map(\.endOffset) == [Int64(start + 48), Int64(start + 53)])
            #expect(page.endOffset == Int64(data.count))
        }
    }
}

@Test func viewerWrappedBoundaryNavigationRoundTrips() async throws {
    let start = 4096 - 13
    let line = "          const index = +e.target.dataset.index;"
    let url = try viewerFixture(Data((String(repeating: "x", count: start - 1) + "\n" + line + "\nnext\n").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    for columns in [80, 120, 200] {
        let document = try FileViewerDocument(url: url)
        var page = try await document.page(.home, rows: 200, wrapColumns: columns)
        while page.offset < start && !page.lines.contains(where: { $0.offset == start }) {
            let next = try await document.page(.scroll(200), rows: 200, wrapColumns: columns)
            #expect(next.offset > page.offset)
            page = next
        }
        #expect(page.lines.first(where: { $0.offset == start })?.text == line)
        page = try await document.page(.scroll(1), rows: 1, wrapColumns: columns)
        while page.offset < start { page = try await document.page(.scroll(1), rows: 1, wrapColumns: columns) }
        #expect(page.offset == start)
        #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: columns).offset == start + 49)
        #expect(try await document.page(.scroll(-1), rows: 1, wrapColumns: columns).offset == start)
        let cold = try await FileViewerDocument(url: url).page(.end, rows: 2, wrapColumns: columns)
        #expect(cold.lines.map(\.text) == [line, "next"])
    }
}

@Test func viewerWrappedLongLineIgnoresBufferBoundaries() async throws {
    let url = try viewerFixture(Data((String(repeating: "x", count: 12_000) + "\nnext").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    for width in [80, 120, 127, 5000] {
        let document = try FileViewerDocument(url: url)
        let total = (12_000 + width - 1) / width + 1
        var lines: [ViewerLine] = []
        var page = try await document.page(.home, rows: 200, wrapColumns: width)
        lines.append(contentsOf: page.lines)
        while lines.count < total {
            page = try await document.page(.scroll(200), rows: 200, wrapColumns: width)
            lines.append(contentsOf: page.lines)
        }
        #expect(lines.count == total)
        for index in 0..<(total - 1) {
            #expect(lines[index].offset == Int64(index * width))
            #expect(lines[index].text == String(repeating: "x", count: min(width, 12_000 - index * width)))
        }
        #expect(lines.last?.offset == 12_001)
        #expect(lines.last?.text == "next")
    }
}

@Test func viewerWrappedExactWidthConsumesLineEnding() async throws {
    for ending in ["\n", "\r\n"] {
        let url = try viewerFixture(Data((String(repeating: "x", count: 4096) + ending + "next").utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FileViewerDocument(url: url)
        let page = try await document.page(.home, rows: 40, wrapColumns: 128)
        #expect(page.lines.count == 33)
        #expect(page.lines.prefix(32).allSatisfy { $0.text == String(repeating: "x", count: 128) })
        #expect(page.lines.last?.text == "next")
        #expect(page.lines.last?.offset == Int64(4096 + ending.utf8.count))
    }
}

@Test func viewerWrappedUTF8AndCRLFCrossReadBoundaries() async throws {
    let emoji = try viewerFixture(Data((String(repeating: "a", count: 4095) + "😀Z\nlast").utf8))
    defer { try? FileManager.default.removeItem(at: emoji) }
    let emojiPage = try await FileViewerDocument(url: emoji).page(rows: 2, wrapColumns: 5000)
    #expect(emojiPage.lines[0].text == String(repeating: "a", count: 4095) + "😀Z")
    #expect(emojiPage.lines.map(\.endOffset) == [4100, 4105])
    #expect(emojiPage.lines[1].offset == 4101)
    let crlf = try viewerFixture(Data((String(repeating: "a", count: 4095) + "\r\nlast").utf8))
    defer { try? FileManager.default.removeItem(at: crlf) }
    let crlfPage = try await FileViewerDocument(url: crlf).page(rows: 2, wrapColumns: 4095)
    #expect(crlfPage.lines.map(\.offset) == [0, 4097])
    #expect(crlfPage.lines.map(\.endOffset) == [4095, 4101])
}

@Test func viewerWrappedTabsAndEOFKeepOffsets() async throws {
    let url = try viewerFixture(Data("ab\tZ\n".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let page = try await FileViewerDocument(url: url).page(rows: 3, wrapColumns: 4, includeSourceText: true)
    #expect(page.lines.map(\.text) == ["ab  ", "Z"])
    #expect(page.lines.map(\.sourceText) == ["ab\t", "Z"])
    #expect(page.lines.map(\.offset) == [0, 3])
    #expect(page.lines.map(\.endOffset) == [3, 4])
    #expect(page.endOffset == 5)
    let tab = try viewerFixture(Data("\tX".utf8))
    defer { try? FileManager.default.removeItem(at: tab) }
    #expect(try await FileViewerDocument(url: tab).page(rows: 2, wrapColumns: 1).lines.map(\.text) == ["    ", "X"])
    let bareCR = try viewerFixture(Data("ab\rZ\n".utf8))
    defer { try? FileManager.default.removeItem(at: bareCR) }
    let crPage = try await FileViewerDocument(url: bareCR).page(rows: 1, wrapColumns: 4, includeSourceText: true)
    #expect(crPage.lines[0].text == "ab·Z")
    #expect(crPage.lines[0].sourceText == "ab\rZ")
}

@Test func viewerWrappedLayoutChangeRealignsTop() async throws {
    let url = try viewerFixture(Data((String(repeating: "x", count: 500) + "\nend").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    _ = try await document.page(.scroll(1), rows: 1, wrapColumns: 120)
    #expect(try await document.page(rows: 1, wrapColumns: 80).offset == 80)
    #expect(try await document.page(.scroll(-1), rows: 1, wrapColumns: 80).offset == 0)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 80).offset == 80)
    let unwrapped = try await document.page(rows: 1)
    #expect(unwrapped.offset == 0)
    #expect(unwrapped.lines[0].text == String(repeating: "x", count: 500))
}

@Test func viewerWrappedTruncationRecoversValidRow() async throws {
    let url = try viewerFixture(Data((String(repeating: "x", count: 20_000) + "\nend\n").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    #expect(try await document.page(.end, rows: 1, wrapColumns: 80).offset == 20_001)
    let start = 4096 - 13
    try Data((String(repeating: "x", count: start - 1) + "\n          const index = +e.target.dataset.index;\nnext\n").utf8).write(to: url)
    let page = try await document.page(rows: 1, wrapColumns: 80)
    #expect(page.offset == 4132)
    #expect(page.lines.first?.text == "next")
    try Data().write(to: url)
    let empty = try await document.page(rows: 1, wrapColumns: 80)
    #expect(empty.offset == 0)
    #expect(empty.lines.isEmpty)
}

@Test func viewerWrappedLongLineRetainsInverseNavigation() async throws {
    let url = try viewerFixture(Data(repeating: 120, count: 120_003))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    _ = try await document.page(.home, rows: 1, wrapColumns: 80)
    var page = try await document.page(rows: 1, wrapColumns: 80)
    while page.offset < 100_000 {
        page = try await document.page(.scroll(200), rows: 1, wrapColumns: 80)
    }
    let saved = page.offset
    let text = page.lines[0].text
    let previous = try await document.page(.scroll(-1), rows: 1, wrapColumns: 80)
    #expect(previous.offset < saved)
    let restored = try await document.page(.scroll(1), rows: 1, wrapColumns: 80)
    #expect(restored.offset == saved)
    #expect(restored.lines[0].text == text)
}

@Test func viewerWrappedColdEndRemainsBounded() async throws {
    let url = try viewerFixture(Data(repeating: 120, count: 120_003))
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
    let end = try await document.page(.end, rows: 3, wrapColumns: 80)
    #expect(end.endOffset == 120_003)
    #expect(end.lines.count == 3)
    #expect(end.lines.allSatisfy { !$0.text.isEmpty && $0.endOffset <= 120_003 })
    #expect(await source.bytesRead < 1_048_576)
    let saved = end.offset
    let previous = try await document.page(.scroll(-1), rows: 1, wrapColumns: 80)
    #expect(previous.offset < saved)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 80).offset == saved)
}

@Test func viewerWrappedColdFallbackAlignsUTF8Scalar() async throws {
    let url = try viewerFixture(Data(("a" + String(repeating: "😀", count: 30_000) + "b").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
    let end = try await document.page(.end, rows: 2, wrapColumns: 80)
    #expect(end.endOffset == 120_002)
    #expect(end.lines.allSatisfy { !$0.text.contains("�") })
    #expect(end.lines.last?.text.hasSuffix("b") == true)
    #expect(await source.bytesRead < 1_048_576)
    let previous = try await document.page(.scroll(-1), rows: 1, wrapColumns: 80)
    #expect(previous.offset < end.offset)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 80).offset == end.offset)
}

@Test func viewerWrappedColdEndFillsRowsAcrossReplayWindows() async throws {
    let ascii = try viewerFixture(Data(repeating: 120, count: 2_000_003))
    defer { try? FileManager.default.removeItem(at: ascii) }
    for (width, count) in [(500, 200), (5000, 30)] {
        let document = try FileViewerDocument(url: ascii)
        let end = try await document.page(.end, rows: count, wrapColumns: width)
        #expect(end.lines.count == count)
        #expect(end.endOffset == 2_000_003)
        let saved = end.offset
        let previous = try await document.page(.scroll(-1), rows: 1, wrapColumns: width)
        #expect(previous.offset < saved)
        #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: width).offset == saved)
    }
    let emoji = try viewerFixture(Data(String(repeating: "😀", count: 500_000).utf8))
    defer { try? FileManager.default.removeItem(at: emoji) }
    for (width, count) in [(180, 100), (240, 80)] {
        let document = try FileViewerDocument(url: emoji)
        let end = try await document.page(.end, rows: count, wrapColumns: width)
        #expect(end.lines.count == count)
        #expect(end.endOffset == 2_000_000)
        #expect(end.lines.allSatisfy { !$0.text.contains("�") })
    }
}

@Test func viewerWrappedHexRoundTripPreservesHistory() async throws {
    let url = try viewerFixture(Data(repeating: 120, count: 120_003))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let end = try await document.page(.end, rows: 1, wrapColumns: 80)
    let previous = try await document.page(.scroll(-1), rows: 1, wrapColumns: 80)
    _ = try await document.page(.scroll(1), rows: 1, wrapColumns: 80)
    _ = try await document.page(rows: 1, mode: .hex)
    let restored = try await document.page(rows: 1, wrapColumns: 80)
    #expect(restored.offset == end.offset)
    #expect(try await document.page(.scroll(-1), rows: 1, wrapColumns: 80).offset == previous.offset)
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 80).offset == end.offset)
}

@Test func viewerMovedHexPositionRecoversEmptyTextRow() async throws {
    let url = try viewerFixture(Data((String(repeating: "x", count: 15) + "\n\nB\n").utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    _ = try await document.page(.home, rows: 1, wrapColumns: 80)
    #expect(try await document.page(.scroll(1), rows: 1, mode: .hex).offset == 16)
    let text = try await document.page(rows: 1, wrapColumns: 80)
    #expect(text.offset == 16)
    #expect(text.lines[0].text == "")
    #expect(try await document.page(.scroll(1), rows: 1, wrapColumns: 80).offset == 17)
}

@Test func viewerScrollsBothDirectionsAndHandlesLineEndings() async throws {
    let url = try viewerFixture(Data("one\r\n\ntwo\nlast".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
    #expect(try await document.page(rows: 2).lines.map(\.text) == ["one", ""])
    #expect(try await document.page(.scroll(1), rows: 2).lines.map(\.text) == ["", "two"])
    #expect(try await document.page(.scroll(-1), rows: 1).lines.map(\.text) == ["one"])
    #expect(try await document.page(.end, rows: 2).lines.map(\.text) == ["two", "last"])
    #expect(try await document.page(.home, rows: 1).offset == 0)
}

@Test func viewerWrapsLongLinesAtVisibleWidthAndScrollsByWrappedRows() async throws {
    let url = try viewerFixture(Data("abcdefghij\nnext".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)

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
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)

    let page = try await document.page(rows: 2)
    #expect(page.lines.count == 2)
    #expect(page.lines[0].text == long)
    #expect(page.lines[1].text == "next")

    let end = try await document.page(.end, rows: 2)
    #expect(end.lines[0].text == long)
    #expect(end.lines[1].text == "next")
}

@Test func viewerOnlyRetainsSourceTextWhenRequested() async throws {
    let url = try viewerFixture(Data("\t\"é\": 1\n".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)

    #expect(try await document.page(rows: 1).lines.first?.sourceText == nil)
    #expect(try await document.page(rows: 1, includeSourceText: true).lines.first?.sourceText == "\t\"é\": 1")
}

@Test func viewerDoesNotSplitUTF8OrCRLFAcrossArtificialRows() async throws {
    for suffix in ["😀Z\nlast", "\r\nlast"] {
        let content = String(repeating: "a", count: 4095) + suffix
        let url = try viewerFixture(Data(content.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
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
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
    let first = try await document.page(rows: 1)
    #expect(first.lines[0].text == "header")
    let end = try await document.page(.end, rows: 4, wrapColumns: 80)
    #expect(end.fileSize == Int64(size))
    #expect(end.lines.last?.text == "last-line")
    #expect(await source.bytesRead < 1_048_576)
    #expect(end.lines.count <= 4)
    #expect(end.lines.allSatisfy { $0.text.utf8.count <= 4096 * 4 })
}

@Test func viewerHandlesEmptyInvalidUTF8AndTruncation() async throws {
    let url = try viewerFixture(Data())
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
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
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
    let page = try await document.page(rows: 3)
    #expect(page.lines.count == 2)
    #expect(page.lines.last?.text == "next")
    _ = try await document.page(.scroll(1), rows: 1)
    #expect(try await document.page(.scroll(-1), rows: 1).offset == 0)
}

@Test func hexShowsAllByteValuesAndAlignsPartialRows() async throws {
    let url = try viewerFixture(Data((0...255).map(UInt8.init)) + Data([0x41]))
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
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
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
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
    let source = try LocalFileContentSource(url: url)
    let document = FileViewerDocument(source: source)
    #expect(try await document.page(.end, rows: 5, mode: .hex).lines.isEmpty)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let size: UInt64 = 8 * 1024 * 1024 * 1024
    try handle.truncate(atOffset: size)
    let last = try await document.page(.end, rows: 2, mode: .hex)
    #expect(last.offset == Int64(size - 32))
    #expect(last.lines[0].text.hasPrefix("00000001FFFFFFE0:"))
    #expect(await source.bytesRead <= 65_536)
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
