import Foundation
import Testing
import TextSearchCore
@testable import FileManagerCore

private final class SearchCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private actor SearchBytes: FileContentSource {
    var bytes: [UInt8]
    var revision: UInt64? = 1
    var knownSize = true
    var origin: Int64 = 0
    var largestRead = 0
    var reads = 0
    var lengthCalls = 0
    var mutateAfterRead: Int? = nil
    var cancelAfterRead: Int? = nil
    var cancellationFlag: SearchCancellationFlag? = nil
    var metadataCalls = 0
    var mutateOnMetadataCall: Int? = nil

    init(_ bytes: [UInt8], origin: Int64 = 0, knownSize: Bool = true) {
        self.bytes = bytes
        self.origin = origin
        self.knownSize = knownSize
    }

    func metadata() -> ContentMetadata {
        metadataCalls += 1
        if mutateOnMetadataCall == metadataCalls { revision = 2 }
        return ContentMetadata(size: knownSize ? origin + Int64(bytes.count) : nil, revision: revision)
    }

    func length() -> Int64 { lengthCalls += 1; return origin + Int64(bytes.count) }

    func read(at offset: Int64, count: Int) -> Data {
        largestRead = max(largestRead, count)
        reads += 1
        if mutateAfterRead == reads { revision = 2 }
        if cancelAfterRead == reads { cancellationFlag?.cancel() }
        if offset < origin {
            let prefix = min(count, Int(origin - offset))
            var data = Data(repeating: 0, count: prefix)
            if prefix < count { data.append(contentsOf: bytes.prefix(count - prefix)) }
            return data
        }
        let start = Int(offset - origin)
        guard start < bytes.count else { return Data() }
        return Data(bytes[start..<min(bytes.count, start + count)])
    }

    func metrics() -> (Int, Int, Int) { (largestRead, reads, lengthCalls) }
    func changeOnRead(_ number: Int) { mutateAfterRead = number }
    func cancelOnRead(_ number: Int, flag: SearchCancellationFlag) {
        cancelAfterRead = number
        cancellationFlag = flag
    }
    func changeOnNextSearchMetadata() { mutateOnMetadataCall = metadataCalls + 2 }
    func append(_ byte: UInt8) { bytes.append(byte) }
    func hideRevision() { revision = nil }
    func replace(_ replacement: [UInt8]) { bytes = replacement }
}

@Test func viewerValidationStopsAfterRemovedCandidate() async throws {
    let bytes = Array("needle".utf8) + Array(repeating: UInt8(0x78), count: 1_000_000)
    let source = SearchBytes(bytes)
    await source.hideRevision()
    let search = ViewerSearchSource(source: source)
    let query = TextSearchQuery(text: "needle", caseSensitive: true)
    let hit = try #require(found(try await search.search(query, direction: .forward, fromByteOffset: 0)))
    await source.replace(Array(repeating: UInt8(0x78), count: bytes.count))
    let previousReads = await source.metrics().1
    #expect(try await !search.validate(hit, query: query))
    #expect(await source.metrics().1 - previousReads <= 2)
}

private func found(_ result: ViewerSearchResult) -> ViewerSearchHit? {
    if case .found(let hit) = result { return hit }
    return nil
}

@Test func viewerSearchDecodesSplitUTF8AndCRLF() async throws {
    let source = SearchBytes(Array("aé\r\nb\rc".utf8))
    let search = ViewerSearchSource(source: source, chunkSize: 1)
    let accented = try await search.search(.init(text: "é\n"), direction: .forward, fromByteOffset: 0)
    #expect(found(accented)?.lowerBound == 1)
    #expect(found(accented)?.upperBound == 5)
    let reverse = try await search.search(.init(text: "é\n"), direction: .backward, fromByteOffset: 100)
    #expect(found(reverse)?.lowerBound == 1)
    #expect(found(reverse)?.upperBound == 5)
    #expect(found(try await search.search(.init(text: "\r"), direction: .forward, fromByteOffset: 0))?.lowerBound == 6)
}

@Test func viewerSearchBarriersAndReverseParity() async throws {
    let source = SearchBytes(Array("aaa".utf8) + [0xFF] + Array("aaa".utf8))
    let search = ViewerSearchSource(source: source, chunkSize: 2)
    let query = TextSearchQuery(text: "aa")
    var forward = [Int64]()
    var cursor: Int64 = 0
    while let hit = found(try await search.search(query, direction: .forward, fromByteOffset: cursor)) {
        forward.append(hit.lowerBound)
        cursor = hit.lowerBound + 1
    }
    var backward = [Int64]()
    cursor = 100
    while let hit = found(try await search.search(query, direction: .backward, fromByteOffset: cursor)) {
        backward.append(hit.lowerBound)
        if hit.lowerBound == 0 { break }
        cursor = hit.lowerBound - 1
    }
    #expect(forward == [0, 1, 4, 5])
    #expect(backward == forward.reversed())
    #expect(found(try await search.search(.init(text: "aaa"), direction: .forward, fromByteOffset: 2))?.lowerBound == 4)
}

@Test func viewerSearchUnknownLengthAndLargeOffsets() async throws {
    let base: Int64 = 4_294_967_296
    let source = SearchBytes(Array("needle".utf8), origin: base, knownSize: false)
    let search = ViewerSearchSource(source: source, chunkSize: 3)
    // The anchor is deliberately near the synthetic data; the fake prefix is
    // sparse to exercise Int64 arithmetic without allocating four GiB.
    let hit = try await search.search(.init(text: "needle"), direction: .backward, fromByteOffset: base + 2)
    #expect(found(hit)?.lowerBound == base)
    #expect(found(hit)?.upperBound == base + 6)
    let metrics = await source.metrics()
    #expect(metrics.0 <= 10) // block plus UTF-8 boundary context
}

@Test func viewerSearchUnknownForwardAndWholeWordBoundaries() async throws {
    let source = SearchBytes(Array("cat! catX cat".utf8), knownSize: false)
    let search = ViewerSearchSource(source: source, chunkSize: 2)
    let query = TextSearchQuery(text: "cat", wholeWord: true)
    let first = try await search.search(query, direction: .forward, fromByteOffset: 0)
    #expect(found(first)?.lowerBound == 0)
    let last = try await search.search(query, direction: .forward, fromByteOffset: 1)
    #expect(found(last)?.lowerBound == 10)
    #expect((await source.metrics()).2 == 0) // forward does not resolve length
    #expect(found(try await search.search(query, direction: .backward, fromByteOffset: 10))?.lowerBound == 10)
    #expect((await source.metrics()).2 > 0)
}

@Test func viewerSearchReverseCaseFoldExpansionAtAnchor() async throws {
    let query = String(repeating: "\u{0390}", count: 3)
    let decomposed = String(repeating: "\u{03B9}\u{0308}\u{0301}", count: 3)
    let source = SearchBytes(Array(decomposed.utf8))
    let search = ViewerSearchSource(source: source, chunkSize: 2)
    #expect(found(try await search.search(.init(text: query), direction: .forward, fromByteOffset: 0))?.lowerBound == 0)
    let backward = try await search.search(.init(text: query), direction: .backward, fromByteOffset: 0)
    #expect(found(backward)?.lowerBound == 0)
    #expect(found(backward)?.upperBound == Int64(decomposed.utf8.count))
}

@Test func viewerSearchValidationTracksResolvedSizeAndRevision() async throws {
    let query = TextSearchQuery(text: "cat")
    let known = SearchBytes(Array("cat".utf8))
    let knownSearch = ViewerSearchSource(source: known, chunkSize: 2)
    let knownHit = try #require(found(try await knownSearch.search(query, direction: .forward, fromByteOffset: 0)))
    #expect(try await knownSearch.validate(knownHit, query: query))
    await known.append(0x21)
    #expect(try await !knownSearch.validate(knownHit, query: query))

    let unknown = SearchBytes(Array("cat".utf8), knownSize: false)
    let unknownSearch = ViewerSearchSource(source: unknown, chunkSize: 2)
    let unknownHit = try #require(found(try await unknownSearch.search(query, direction: .backward, fromByteOffset: 0)))
    #expect(unknownHit.sourceSize == 3)
    #expect(try await unknownSearch.validate(unknownHit, query: query))
    await unknown.append(0x21)
    #expect(try await !unknownSearch.validate(unknownHit, query: query))

    let raced = SearchBytes(Array("cat".utf8))
    let racedSearch = ViewerSearchSource(source: raced, chunkSize: 2)
    let racedHit = try #require(found(try await racedSearch.search(query, direction: .forward, fromByteOffset: 0)))
    await raced.changeOnNextSearchMetadata()
    #expect(try await !racedSearch.validate(racedHit, query: query))

    // A reverse whole-word hit at BOF is emitted by `finish`, after the loop.
    let bof = SearchBytes(Array("cat!".utf8), knownSize: false)
    await bof.hideRevision()
    let bofSearch = ViewerSearchSource(source: bof, chunkSize: 2)
    let wholeWord = TextSearchQuery(text: "cat", wholeWord: true)
    let bofHit = try #require(found(try await bofSearch.search(wholeWord, direction: .backward, fromByteOffset: 0)))
    #expect(bofHit.sourceSize == 4)
    #expect(try await bofSearch.validate(bofHit, query: wholeWord))
    await bof.append(0x58)
    #expect(try await !bofSearch.validate(bofHit, query: wholeWord))
}

@Test func viewerSearchRevisionAndCancellation() async throws {
    let source = SearchBytes(Array(repeating: 0x61, count: 10_000))
    await source.changeOnRead(2)
    let search = ViewerSearchSource(source: source, chunkSize: 256)
    #expect(try await search.search(.init(text: "z"), direction: .forward, fromByteOffset: 0) == .sourceChanged)

    let noMatch = SearchBytes(Array(repeating: 0x61, count: 10_000))
    let other = ViewerSearchSource(source: noMatch, chunkSize: 256)
    let task = Task { try await other.search(.init(text: "z"), direction: .forward, fromByteOffset: 0) }
    task.cancel()
    #expect(try await task.value == .cancelled)

    let during = SearchBytes(Array(repeating: 0x61, count: 10_000))
    let flag = SearchCancellationFlag()
    await during.cancelOnRead(3, flag: flag)
    let duringSearch = ViewerSearchSource(source: during, chunkSize: 256)
    #expect(try await duringSearch.search(.init(text: "z"), direction: .forward,
                                          fromByteOffset: 0, isCancelled: { flag.isCancelled() }) == .cancelled)
    #expect((await during.metrics()).1 == 3)
}

@Test func viewerSearchExclusiveStartLimitBoundsBothDirections() async throws {
    let source = SearchBytes(Array("xxxxABCD----ABCD----".utf8))
    let search = ViewerSearchSource(source: source, chunkSize: 2)
    let query = TextSearchQuery(text: "ABCD")
    let forward = try await search.search(query, direction: .forward, fromByteOffset: 0,
                                          exclusiveStartLimit: 6)
    #expect(found(forward)?.lowerBound == 4)
    #expect(found(forward)?.upperBound == 8)
    #expect(try await search.search(query, direction: .forward, fromByteOffset: 8,
                                    exclusiveStartLimit: 12) == .exhausted)
    let backward = try await search.search(query, direction: .backward, fromByteOffset: 18,
                                           exclusiveStartLimit: 11)
    #expect(found(backward)?.lowerBound == 12)
    #expect(try await search.search(query, direction: .backward, fromByteOffset: 11,
                                    exclusiveStartLimit: 4) == .exhausted)
    let readsBefore = (await source.metrics()).1
    #expect(try await search.search(query, direction: .forward, fromByteOffset: 12,
                                    exclusiveStartLimit: 12) == .exhausted)
    #expect((await source.metrics()).1 == readsBefore)

    let longSource = SearchBytes(Array(repeating: 0x78, count: 10_000))
    let bounded = ViewerSearchSource(source: longSource, chunkSize: 32)
    #expect(try await bounded.search(.init(text: "z"), direction: .forward,
                                      fromByteOffset: 0, exclusiveStartLimit: 100) == .exhausted)
    #expect((await longSource.metrics()).1 < 10)
}

@Test func viewerASCIIPathMatchesScalarScannerAcrossChunksAndLimits() async throws {
    let source = SearchBytes(Array("--AbC--abc--ABC--".utf8))
    let fast = ViewerSearchSource(source: source, chunkSize: 8)
    let scalar = ViewerSearchSource(source: source, chunkSize: 2) // query is longer than a block
    for query in [TextSearchQuery(text: "AbC", caseSensitive: true),
                  TextSearchQuery(text: "AbC", caseSensitive: false)] {
        for direction in [SearchDirection.forward, .backward] {
            for anchor: Int64 in [0, 2, 4, 7, 8, 12, 16] {
                for limit: Int64? in [nil, 3, 8, 12] {
                    let actual = try await fast.search(query, direction: direction,
                                                       fromByteOffset: anchor,
                                                       exclusiveStartLimit: limit)
                    let expected = try await scalar.search(query, direction: direction,
                                                           fromByteOffset: anchor,
                                                           exclusiveStartLimit: limit)
                    #expect(actual == expected)
                }
            }
        }
    }
}

@Test func viewerASCIIPathFallsBackForUnicodeFoldingAndPreservesBarriers() async throws {
    let folded = SearchBytes(Array("xxxxKabc".utf8))
    let fast = ViewerSearchSource(source: folded, chunkSize: 8)
    let query = TextSearchQuery(text: "kabc")
    #expect(found(try await fast.search(query, direction: .forward, fromByteOffset: 0))?.lowerBound == 4)
    #expect(found(try await fast.search(query, direction: .backward, fromByteOffset: 100))?.lowerBound == 4)

    let expansion = SearchBytes(Array("xxxxﬀ".utf8))
    let expansionSearch = ViewerSearchSource(source: expansion, chunkSize: 8)
    let foldedQuery = TextSearchQuery(text: "ff")
    #expect(found(try await expansionSearch.search(foldedQuery, direction: .forward,
                                                   fromByteOffset: 0, exclusiveStartLimit: 5))?.lowerBound == 4)
    #expect(found(try await expansionSearch.search(foldedQuery, direction: .backward,
                                                   fromByteOffset: 4, exclusiveStartLimit: 3))?.lowerBound == 4)

    let malformed = SearchBytes(Array("ab".utf8) + [0xFF] + Array("ab".utf8))
    let bytes = ViewerSearchSource(source: malformed, chunkSize: 3)
    let scalar = ViewerSearchSource(source: malformed, chunkSize: 1)
    let exact = TextSearchQuery(text: "ab", caseSensitive: true)
    for (direction, anchor) in [(SearchDirection.forward, Int64(0)), (.forward, 1), (.backward, 4)] {
        let actual = try await bytes.search(exact, direction: direction, fromByteOffset: anchor)
        let expected = try await scalar.search(exact, direction: direction, fromByteOffset: anchor)
        #expect(actual == expected)
    }
}

@Test func viewerSIMDBlocksFallBackBeforeLaterASCIIHitsInBothDirections() async throws {
    let text = String(repeating: "x", count: 32) + "ßSS" + String(repeating: "x", count: 40)
    let source = SearchBytes(Array(text.utf8))
    let fast = ViewerSearchSource(source: source, chunkSize: 64)
    let scalar = ViewerSearchSource(source: source, chunkSize: 1)
    let folded = TextSearchQuery(text: "ss")
    for (direction, anchor) in [(SearchDirection.forward, Int64(0)),
                                (.backward, Int64(text.utf8.count - 1)),
                                (.backward, Int64(32))] {
        let actual = try await fast.search(folded, direction: direction, fromByteOffset: anchor)
        let expected = try await scalar.search(folded, direction: direction, fromByteOffset: anchor)
        #expect(actual == expected)
    }
    #expect(found(try await fast.search(folded, direction: .forward, fromByteOffset: 0))?.lowerBound == 32)
    #expect(found(try await fast.search(folded, direction: .backward,
                                        fromByteOffset: Int64(text.utf8.count - 1)))?.lowerBound == 34)
    let sensitive = TextSearchQuery(text: "SS", caseSensitive: true)
    #expect(found(try await fast.search(sensitive, direction: .forward, fromByteOffset: 0))?.lowerBound == 34)
}

@Test func viewerASCIIPathHandlesUnknownLengthAndLargeByteOffsets() async throws {
    let base: Int64 = 4_294_967_296
    let source = SearchBytes(Array("xneedle".utf8), origin: base, knownSize: false)
    let search = ViewerSearchSource(source: source, chunkSize: 16)
    let query = TextSearchQuery(text: "needle", caseSensitive: true)
    let forward = try await search.search(query, direction: .forward, fromByteOffset: base)
    #expect(found(forward)?.lowerBound == base + 1)
    #expect(found(forward)?.sourceSize == nil)
    let backward = try await search.search(query, direction: .backward, fromByteOffset: base + 1)
    #expect(found(backward)?.lowerBound == base + 1)
    #expect(found(backward)?.sourceSize == base + 7)
    #expect(try await search.validate(try #require(found(backward)), query: query))
}

@Test func viewerASCIIPathAgreesWithScalarScannerForGeneratedInputs() async throws {
    var state: UInt64 = 0xBADC0FFEE
    for _ in 0..<24 {
        var bytes = [UInt8]()
        for _ in 0..<48 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            bytes.append([UInt8(ascii: "a"), UInt8(ascii: "b"), UInt8(ascii: "C")][Int(state % 3)])
        }
        bytes.replaceSubrange(6..<9, with: Array("abC".utf8))
        bytes.replaceSubrange(14..<17, with: Array("abC".utf8))
        let source = SearchBytes(bytes)
        let fast = ViewerSearchSource(source: source, chunkSize: 8)
        let scalar = ViewerSearchSource(source: source, chunkSize: 2)
        for query in [TextSearchQuery(text: "abC", caseSensitive: true),
                      TextSearchQuery(text: "abC")] {
            for direction in [SearchDirection.forward, .backward] {
                for anchor: Int64 in [0, 7, 16, 30, 47] {
                    for limit: Int64? in [nil, 8, 15, 35] {
                        let actual = try await fast.search(query, direction: direction,
                                                           fromByteOffset: anchor, exclusiveStartLimit: limit)
                        let expected = try await scalar.search(query, direction: direction,
                                                               fromByteOffset: anchor, exclusiveStartLimit: limit)
                        #expect(actual == expected)
                    }
                }
            }
        }
    }
}
