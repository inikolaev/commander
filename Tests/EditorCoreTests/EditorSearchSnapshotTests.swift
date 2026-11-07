import Foundation
import Testing
import EditorCore
import TextSearchCore

private func found(_ result: EditorSearchResult) -> EditorSearchHit? {
    if case .found(let hit) = result { return hit }
    return nil
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let limit: Int
    init(limit: Int = 10) { self.limit = limit }
    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= limit
    }
    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }
}

@Test @MainActor func editorASCIIPathMatchesScalarScannerAcrossAnchorsAndLimits() {
    let snapshot = EditorDocuments.make(text: "--AbC--abc--ABC--").makeSearchSnapshot()
    for query in [TextSearchQuery(text: "AbC", caseSensitive: true),
                  TextSearchQuery(text: "AbC")] {
        for direction in [SearchDirection.forward, .backward] {
            for anchor in [0, 2, 4, 7, 8, 12, 16] {
                for limit: Int? in [nil, 3, 8, 12] {
                    let fast = snapshot.search(query, direction: direction,
                                               fromUTF16Offset: anchor,
                                               exclusiveStartLimit: limit, chunkSize: 8)
                    let scalar = snapshot.search(query, direction: direction,
                                                 fromUTF16Offset: anchor,
                                                 exclusiveStartLimit: limit, chunkSize: 2)
                    #expect(fast == scalar)
                }
            }
        }
    }
}

@Test @MainActor func editorASCIIPathFallsBackForUnicodeFoldingAndSurrogateAnchors() {
    let expanded = EditorDocuments.make(text: "xxxxﬀ").makeSearchSnapshot()
    let query = TextSearchQuery(text: "ff")
    for direction in [SearchDirection.forward, .backward] {
        let anchor = direction == .forward ? 0 : 4
        let limit = direction == .forward ? 5 : 3
        #expect(expanded.search(query, direction: direction, fromUTF16Offset: anchor,
                                exclusiveStartLimit: limit, chunkSize: 8)
                == expanded.search(query, direction: direction, fromUTF16Offset: anchor,
                                   exclusiveStartLimit: limit, chunkSize: 1))
    }

    let emoji = EditorDocuments.make(text: "😀abc").makeSearchSnapshot()
    let exact = TextSearchQuery(text: "abc", caseSensitive: true)
    #expect(emoji.search(exact, direction: .forward, fromUTF16Offset: 1, chunkSize: 8)
            == emoji.search(exact, direction: .forward, fromUTF16Offset: 1, chunkSize: 2))
    #expect(emoji.search(exact, direction: .backward, fromUTF16Offset: 2, chunkSize: 8)
            == emoji.search(exact, direction: .backward, fromUTF16Offset: 2, chunkSize: 2))
}

@Test @MainActor func editorASCIIPathAgreesWithScalarScannerForGeneratedUnicodeInputs() {
    let pieces = ["a", "b", "C", "ﬀ", "😀", "e\u{301}", "K", "\r\n"]
    var state: UInt64 = 0xA11CE
    for _ in 0..<12 {
        var text = "abC"
        for _ in 0..<28 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            text += pieces[Int(state % UInt64(pieces.count))]
        }
        text += "abC"
        let snapshot = EditorDocuments.make(text: text).makeSearchSnapshot()
        let anchors = [0, 1, 2, snapshot.length / 2, snapshot.length - 1, snapshot.length,
                       snapshot.length + 3]
        let limits: [Int?] = [nil, 0, snapshot.length / 3, snapshot.length - 1]
        for query in [TextSearchQuery(text: "abC", caseSensitive: true),
                      TextSearchQuery(text: "abC"), TextSearchQuery(text: "ff")] {
            for direction in [SearchDirection.forward, .backward] {
                for anchor in anchors {
                    for limit in limits {
                        let fast = snapshot.search(query, direction: direction,
                                                   fromUTF16Offset: anchor,
                                                   exclusiveStartLimit: limit, chunkSize: 8)
                        let scalar = snapshot.search(query, direction: direction,
                                                     fromUTF16Offset: anchor,
                                                     exclusiveStartLimit: limit, chunkSize: 1)
                        #expect(fast == scalar)
                    }
                }
            }
        }
    }
}

@Test @MainActor func anchoredScansDoBoundedWorkWithUnicodeContext() {
    let prefix = String(repeating: "x", count: 1_000_000)
    let suffix = String(repeating: "y", count: 1_000_000)
    let snapshot = EditorDocuments.make(text: "ﬃ " + prefix + " 😀straße " + suffix + " ﬃ").makeSearchSnapshot()
    let forwardProbe = CancellationProbe(limit: .max)
    let forward = snapshot.search(.init(text: "ffi", wholeWord: true), direction: .forward,
                                  fromUTF16Offset: snapshot.length - 1, chunkSize: 37,
                                  isCancelled: { forwardProbe.shouldCancel() })
    #expect(found(forward)?.exactRange == NSRange(location: snapshot.length - 1, length: 1))
    #expect(forwardProbe.checkCount < 500)

    let reverseProbe = CancellationProbe(limit: .max)
    let reverse = snapshot.search(.init(text: "ffi", wholeWord: true), direction: .backward,
                                  fromUTF16Offset: 0, chunkSize: 37,
                                  isCancelled: { reverseProbe.shouldCancel() })
    #expect(found(reverse)?.exactRange == NSRange(location: 0, length: 1))
    #expect(reverseProbe.checkCount < 500)

    let noHitProbe = CancellationProbe(limit: .max)
    #expect(snapshot.search(.init(text: "absent", caseSensitive: true), direction: .forward,
                            fromUTF16Offset: snapshot.length - 10, chunkSize: 37,
                            isCancelled: { noHitProbe.shouldCancel() }) == .exhausted)
    #expect(noHitProbe.checkCount < 100)

    // The anchor may fall between the two UTF-16 units of an emoji. The
    // following word is still found, and reverse matching can include it.
    let emoji = ("ﬃ " + prefix + " ").utf16.count
    #expect(found(snapshot.search(.init(text: "straße", wholeWord: true), direction: .forward,
                                  fromUTF16Offset: emoji + 1, chunkSize: 1))?.exactRange.location == emoji + 2)
    #expect(found(snapshot.search(.init(text: "😀", caseSensitive: true), direction: .backward,
                                  fromUTF16Offset: emoji, chunkSize: 1))?.exactRange.location == emoji)
}

@Test @MainActor func anchoredScansPreserveSurrogateBoundariesInBothDirections() {
    let mixed = EditorDocuments.make(text: "😀i🇦😀\u{301}😀").makeSearchSnapshot()
    #expect(mixed.search(.init(text: "aaa"), direction: .forward,
                         fromUTF16Offset: 5, chunkSize: 2) == .exhausted)
    let flags = EditorDocuments.make(text: "🇦🇧🇨🇩🇪🇫🇬").makeSearchSnapshot()
    #expect(flags.search(.init(text: "🇨", caseSensitive: true), direction: .backward,
                         fromUTF16Offset: 1, chunkSize: 3) == .exhausted)
    #expect(found(flags.search(.init(text: "🇨", caseSensitive: true), direction: .forward,
                               fromUTF16Offset: 1, chunkSize: 3))?.exactRange.location == 4)
}

@Test @MainActor func unicodePrefixDoesNotForceTailSelectionToScanFromBOF() {
    let prefix = String(repeating: "Жe\u{301}", count: 50_000)
    let snapshot = EditorDocuments.make(text: prefix + " needle").makeSearchSnapshot()
    let probe = CancellationProbe(limit: .max)
    let result = snapshot.search(.init(text: "needle", caseSensitive: true), direction: .backward,
                                 fromUTF16Offset: snapshot.length - 1,
                                 isCancelled: { probe.shouldCancel() })
    #expect(found(result)?.exactRange.location == snapshot.length - 6)
    #expect(probe.checkCount < 1_000)
}

@Test @MainActor func exclusiveStartLimitKeepsWrapIntervalsDisjoint() {
    let snapshot = EditorDocuments.make(text: "aa aa aa").makeSearchSnapshot()
    let query = TextSearchQuery(text: "aa", caseSensitive: true)
    #expect(found(snapshot.search(query, direction: .forward, fromUTF16Offset: 0,
                                  exclusiveStartLimit: 3, chunkSize: 1))?.exactRange.location == 0)
    #expect(snapshot.search(query, direction: .forward, fromUTF16Offset: 1,
                            exclusiveStartLimit: 3, chunkSize: 1) == .exhausted)
    #expect(found(snapshot.search(query, direction: .backward, fromUTF16Offset: 7,
                                  exclusiveStartLimit: 3, chunkSize: 1))?.exactRange.location == 6)
    #expect(snapshot.search(query, direction: .backward, fromUTF16Offset: 3,
                            exclusiveStartLimit: 3, chunkSize: 1) == .exhausted)
}

@Test @MainActor func boundedWrapScansKeepFoldExpansionAndLeftWordBoundary() {
    let expandedSource = EditorDocuments.make(text: "ffiffiffiffi" + String(repeating: "x", count: 100)).makeSearchSnapshot()
    let ligatureQuery = TextSearchQuery(text: "ﬃﬃﬃﬃ")
    #expect(found(expandedSource.search(ligatureQuery, direction: .forward, fromUTF16Offset: 0,
                                        exclusiveStartLimit: 1, chunkSize: 1))?.exactRange
            == NSRange(location: 0, length: 12))
    let ligatures = EditorDocuments.make(text: "ﬃﬃﬃﬃ z").makeSearchSnapshot()
    let folded = TextSearchQuery(text: "ffiffiffiffi")
    #expect(found(ligatures.search(folded, direction: .forward, fromUTF16Offset: 0,
                                   exclusiveStartLimit: 1, chunkSize: 1))?.exactRange
            == NSRange(location: 0, length: 4))
    let emoji = EditorDocuments.make(text: "😀foo x").makeSearchSnapshot()
    let word = TextSearchQuery(text: "foo", wholeWord: true)
    #expect(found(emoji.search(word, direction: .backward, fromUTF16Offset: emoji.length,
                              exclusiveStartLimit: 1, chunkSize: 1))?.exactRange
            == NSRange(location: 2, length: 3))
}

@Test @MainActor func snapshotIsStableAcrossReplaceUndoRedoAndDoesNotChangeHistory() {
    let document = EditorDocuments.make(text: "old target")
    let version = document.contentVersion
    let snapshot = document.makeSearchSnapshot()
    #expect(document.contentVersion == version)
    #expect(!document.isModified)
    #expect(!document.canUndo)
    #expect(!document.canRedo)
    let oldHit = found(snapshot.search(.init(text: "target"), direction: .forward, fromUTF16Offset: 0))!
    #expect(oldHit.exactRange == NSRange(location: 4, length: 6))
    document.replace(NSRange(location: 4, length: 6), with: "fresh")
    #expect(!oldHit.isCurrent(contentVersion: document.contentVersion))
    #expect(found(snapshot.search(.init(text: "target"), direction: .forward, fromUTF16Offset: 0)) == oldHit)
    let changed = document.makeSearchSnapshot()
    #expect(found(changed.search(.init(text: "fresh"), direction: .forward, fromUTF16Offset: 0))?.contentVersion == 1)
    document.undo()
    #expect(document.contentVersion == 2)
    #expect(found(snapshot.search(.init(text: "target"), direction: .forward, fromUTF16Offset: 0)) == oldHit)
    document.redo()
    #expect(document.contentVersion == 3)
    #expect(found(snapshot.search(.init(text: "target"), direction: .forward, fromUTF16Offset: 0)) == oldHit)
    #expect(document.isModified)
    #expect(document.canUndo)
    #expect(!document.canRedo)
}

@Test @MainActor func exactUTF16AndGraphemeSafeSelection() {
    let text = "x👩‍💻e\u{301}z"
    let snapshot = EditorDocuments.make(text: text).makeSearchSnapshot()
    let woman = found(snapshot.search(.init(text: "👩", caseSensitive: true), direction: .forward, fromUTF16Offset: 0, chunkSize: 1))!
    #expect(woman.exactRange == NSRange(location: 1, length: 2))
    #expect(woman.selectionRange == NSRange(location: 1, length: "👩‍💻".utf16.count))
    let mark = found(snapshot.search(.init(text: "\u{301}", caseSensitive: true), direction: .forward, fromUTF16Offset: 0, chunkSize: 1))!
    #expect(mark.exactRange == NSRange(location: 7, length: 1))
    #expect(mark.selectionRange == NSRange(location: 6, length: 2))
    let full = found(snapshot.search(.init(text: "👩‍💻e\u{301}", caseSensitive: true), direction: .forward, fromUTF16Offset: 0, chunkSize: 1))!
    #expect(full.exactRange == NSRange(location: 1, length: 7))
    #expect(full.selectionRange == full.exactRange)
}

@Test @MainActor func chunkPartitionsAndReverseMatchStartParity() {
    let text = "z" + String(repeating: "e\u{301}", count: 100) + " aaa aaa z"
    let snapshot = EditorDocuments.make(text: text).makeSearchSnapshot()
    for size in [1, 2, 3, 7, 64, 65_536] {
        var forward: [NSRange] = []
        var start = 0
        while let hit = found(snapshot.search(.init(text: "aaa", caseSensitive: true), direction: .forward,
                                               fromUTF16Offset: start, chunkSize: size)) {
            forward.append(hit.exactRange)
            start = hit.exactRange.location + 1
        }
        var backward: [NSRange] = []
        start = snapshot.length
        while let hit = found(snapshot.search(.init(text: "aaa", caseSensitive: true), direction: .backward,
                                               fromUTF16Offset: start, chunkSize: size)) {
            backward.append(hit.exactRange)
            start = hit.exactRange.location - 1
        }
        #expect(forward == backward.reversed())
        #expect(forward.count == 2)
    }
}

@Test @MainActor func overlapWholeWordAndCancelledNoHit() {
    let snapshot = EditorDocuments.make(text: "aaaaa xfoo foo").makeSearchSnapshot()
    #expect(found(snapshot.search(.init(text: "aaa", caseSensitive: true), direction: .forward, fromUTF16Offset: 0, chunkSize: 2))?.exactRange.location == 0)
    #expect(found(snapshot.search(.init(text: "aaa", caseSensitive: true), direction: .forward, fromUTF16Offset: 1, chunkSize: 2))?.exactRange.location == 1)
    #expect(found(snapshot.search(.init(text: "aaa", caseSensitive: true), direction: .backward, fromUTF16Offset: 2, chunkSize: 2))?.exactRange.location == 2)
    #expect(found(snapshot.search(.init(text: "foo", wholeWord: true), direction: .forward,
                                  fromUTF16Offset: 0, chunkSize: 1))?.exactRange.location == 11)
    let long = EditorDocuments.make(text: String(repeating: "a", count: 100_000)).makeSearchSnapshot()
    let cancelled = long.search(.init(text: "z"), direction: .forward, fromUTF16Offset: 0,
                                chunkSize: 127, isCancelled: { true })
    #expect(cancelled == .cancelled)
    let probe = CancellationProbe()
    let duringScan = long.search(.init(text: "z"), direction: .forward, fromUTF16Offset: 0,
                                 chunkSize: 127, isCancelled: { probe.shouldCancel() })
    #expect(duringScan == .cancelled)
}

@Test @MainActor func cancellationDuringSelectionExpansionDoesNotPublishHit() {
    let snapshot = EditorDocuments.make(text: "e" + String(repeating: "\u{301}", count: 200_000)).makeSearchSnapshot()
    let probe = CancellationProbe(limit: 12)
    let result = snapshot.search(.init(text: "e", caseSensitive: true), direction: .forward,
                                 fromUTF16Offset: 0, chunkSize: 1,
                                 isCancelled: { probe.shouldCancel() })
    #expect(result == .cancelled)
}

@Test @MainActor func veryLongGraphemeDoesNotDuplicateAcrossRequestedChunks() {
    let grapheme = "e" + String(repeating: "\u{301}", count: 20_000)
    let snapshot = EditorDocuments.make(text: "a" + grapheme + "tail").makeSearchSnapshot()
    for size in [1, 7, 64] {
        let tail = found(snapshot.search(.init(text: "tail", caseSensitive: true), direction: .forward,
                                         fromUTF16Offset: 0, chunkSize: size))!
        #expect(tail.exactRange.location == 1 + grapheme.utf16.count)
        let reverse = found(snapshot.search(.init(text: "tail", caseSensitive: true), direction: .backward,
                                            fromUTF16Offset: snapshot.length, chunkSize: size))!
        #expect(reverse == tail)
        let mark = found(snapshot.search(.init(text: "\u{301}", caseSensitive: true), direction: .forward,
                                         fromUTF16Offset: 0, chunkSize: size))!
        #expect(mark.exactRange == NSRange(location: 2, length: 1))
        #expect(mark.selectionRange == NSRange(location: 1, length: grapheme.utf16.count))
    }
}

@Test @MainActor func prependedDigitSelectionIsChunkIndependentInBothDirections() {
    let snapshot = EditorDocuments.make(text: "\u{0600}1").makeSearchSnapshot()
    for size in [1, 2, 65_536] {
        let forward = found(snapshot.search(.init(text: "1", caseSensitive: true), direction: .forward,
                                            fromUTF16Offset: 0, chunkSize: size))!
        let backward = found(snapshot.search(.init(text: "1", caseSensitive: true), direction: .backward,
                                             fromUTF16Offset: snapshot.length, chunkSize: size))!
        #expect(forward == backward)
        #expect(forward.exactRange == NSRange(location: 1, length: 1))
        #expect(forward.selectionRange == NSRange(location: 0, length: 2))
    }
}

@Test @MainActor func reverseZWJBoundaryNeverProducesNegativeChunkOrigin() {
    for text in ["a\u{200D}b", "a\u{200D}b" + String(repeating: "x", count: 65_535)] {
        let snapshot = EditorDocuments.make(text: text).makeSearchSnapshot()
        for size in [1, 2, 65_536] {
            let hit = found(snapshot.search(.init(text: "a", caseSensitive: true), direction: .backward,
                                            fromUTF16Offset: snapshot.length, chunkSize: size))!
            #expect(hit.exactRange == NSRange(location: 0, length: 1))
            #expect(hit.selectionRange.location == 0)
            #expect(NSMaxRange(hit.selectionRange) <= snapshot.length)
        }
    }
}

@Test @MainActor func adjacentSupplementaryScalarsStayDistinctAtChunkEdges() {
    let cases = [
        ("🇦🇧🇨", "🇦", 2),
        (String(repeating: "x", count: 65_534) + "😀😀", "z", 65_536),
    ]
    for (text, query, size) in cases {
        let snapshot = EditorDocuments.make(text: text).makeSearchSnapshot()
        let forward = snapshot.search(.init(text: query, caseSensitive: true), direction: .forward,
                                      fromUTF16Offset: 0, chunkSize: size)
        let backward = snapshot.search(.init(text: query, caseSensitive: true), direction: .backward,
                                       fromUTF16Offset: snapshot.length, chunkSize: size)
        if query == "z" {
            #expect(forward == .exhausted)
            #expect(backward == .exhausted)
        } else {
            #expect(found(forward)?.exactRange == NSRange(location: 0, length: 2))
            #expect(found(backward) == found(forward))
        }
    }
}

@Test @MainActor func longEmojiJoinerClusterSelectionUsesFullSwiftGrapheme() {
    for extender in ["\u{301}", "\u{FF9E}"] {
        let cluster = "👩" + String(repeating: extender, count: 300) + "\u{200D}💻"
        #expect(cluster.count == 1)
        let snapshot = EditorDocuments.make(text: cluster + "x").makeSearchSnapshot()
        for size in [1, 2, 128, 65_536] {
            let forward = found(snapshot.search(.init(text: "💻", caseSensitive: true), direction: .forward,
                                                fromUTF16Offset: 0, chunkSize: size))!
            let backward = found(snapshot.search(.init(text: "💻", caseSensitive: true), direction: .backward,
                                                 fromUTF16Offset: snapshot.length, chunkSize: size))!
            #expect(forward == backward)
            #expect(forward.exactRange == NSRange(location: cluster.utf16.count - 2, length: 2))
            #expect(forward.selectionRange == NSRange(location: 0, length: cluster.utf16.count))
        }
    }
}
