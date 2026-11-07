import Foundation
import Testing
@_spi(Benchmark) import TextSearchCore

@Test func asciiLiteralShortcutOnlyAcceptsEquivalentScalarSemantics() {
    #expect(ASCIILiteralQuery(query: .init(text: ""), maximumLength: 8)?.pattern == nil)
    #expect(ASCIILiteralQuery(query: .init(text: "ab", wholeWord: true), maximumLength: 8)?.pattern == nil)
    #expect(ASCIILiteralQuery(query: .init(text: "a\nb"), maximumLength: 8)?.pattern == nil)
    #expect(ASCIILiteralQuery(query: .init(text: "a\rb"), maximumLength: 8)?.pattern == nil)
    #expect(ASCIILiteralQuery(query: .init(text: "é"), maximumLength: 8)?.pattern == nil)
    #expect(ASCIILiteralQuery(query: .init(text: "abcdefgh"), maximumLength: 7)?.pattern == nil)

    let insensitive = ASCIILiteralQuery(query: .init(text: "AbC"), maximumLength: 8)!
    #expect(insensitive.pattern == Data("abc".utf8))
    #expect(insensitive.preparedBlock(Data("XyZ".utf8), requireASCII: true) == Data("xyz".utf8))
    #expect(insensitive.preparedBlock(Data("K".utf8), requireASCII: false) == nil)

    let sensitive = ASCIILiteralQuery(query: .init(text: "AbC", caseSensitive: true), maximumLength: 8)!
    #expect(sensitive.pattern == Data("AbC".utf8))
    #expect(sensitive.preparedBlock(Data("K".utf8), requireASCII: false) == Data("K".utf8))
    #expect(sensitive.preparedBlock(Data("K".utf8), requireASCII: true) == nil)
}

@Test func asciiScannerFindsBoundaryMatchesInBothDirections() {
    let query = ASCIILiteralQuery(query: .init(text: "AbC"), maximumLength: 8)!
    var forward = ASCIILiteralScanner<Int>(query: query, direction: .forward)
    if case .advance = forward.consume(Data("xxA".utf8), startingAt: 0, requireASCII: true) {}
    else { Issue.record("unexpected first-block match") }
    if case .match(let hit) = forward.consume(Data("bCxx".utf8), startingAt: 3, requireASCII: true) {
        #expect(hit.lowerBound == 2 && hit.upperBound == 5)
    } else { Issue.record("missing forward boundary match") }

    var backward = ASCIILiteralScanner<Int>(query: query, direction: .backward)
    if case .advance = backward.consume(Data("bCxx".utf8), startingAt: 3, requireASCII: true) {}
    else { Issue.record("unexpected first-block match") }
    if case .match(let hit) = backward.consume(Data("xxA".utf8), startingAt: 0, requireASCII: true) {
        #expect(hit.lowerBound == 2 && hit.upperBound == 5)
    } else { Issue.record("missing backward boundary match") }
}

@Test func asciiScannerRequestsUnicodeFallback() {
    let query = ASCIILiteralQuery(query: .init(text: "k"), maximumLength: 8)!
    var scanner = ASCIILiteralScanner<Int>(query: query, direction: .forward)
    if case .requiresUnicode = scanner.consume(Data("K".utf8), startingAt: 0, requireASCII: false) {}
    else { Issue.record("Unicode text must use full case folding") }
}

@Test func asciiScannerKeepsCarryAcrossThreeShortBlocks() {
    let query = ASCIILiteralQuery(query: .init(text: "abc", caseSensitive: true), maximumLength: 3)!
    var forward = ASCIILiteralScanner<Int>(query: query, direction: .forward)
    if case .advance = forward.consume(Data("a".utf8), startingAt: 0, requireASCII: false) {}
    else { Issue.record("first block should not match") }
    if case .advance = forward.consume(Data("b".utf8), startingAt: 1, requireASCII: false) {}
    else { Issue.record("second block should not match") }
    if case .match(let hit) = forward.consume(Data("c".utf8), startingAt: 2, requireASCII: false) {
        #expect(hit.lowerBound == 0 && hit.upperBound == 3)
    } else { Issue.record("forward match lost across short blocks") }

    var backward = ASCIILiteralScanner<Int>(query: query, direction: .backward)
    if case .advance = backward.consume(Data("c".utf8), startingAt: 2, requireASCII: false) {}
    else { Issue.record("first block should not match") }
    if case .advance = backward.consume(Data("b".utf8), startingAt: 1, requireASCII: false) {}
    else { Issue.record("second block should not match") }
    if case .match(let hit) = backward.consume(Data("a".utf8), startingAt: 0, requireASCII: false) {
        #expect(hit.lowerBound == 0 && hit.upperBound == 3)
    } else { Issue.record("backward match lost across short blocks") }
}

@Test func asciiScannerUsesRelativeOffsetsForDataSlices() {
    let query = ASCIILiteralQuery(query: .init(text: "abc", caseSensitive: true), maximumLength: 3)!
    let bytes = Data("xxabcxx".utf8)
    let slice = bytes[2..<5]
    #expect(slice.startIndex == 2)
    for direction in [SearchDirection.forward, .backward] {
        var scanner = ASCIILiteralScanner<Int>(query: query, direction: direction)
        if case .match(let hit) = scanner.consume(slice, startingAt: 100, requireASCII: false) {
            #expect(hit.lowerBound == 100 && hit.upperBound == 103)
        } else { Issue.record("sliced block did not match") }
    }
}
private func scalarPrepared(_ input: Data, caseSensitive: Bool, requireASCII: Bool) -> Data? {
    if caseSensitive && !requireASCII { return input }
    var result = Data()
    result.reserveCapacity(input.count)
    for byte in input {
        if byte >= 0x80 { return nil }
        result.append(!caseSensitive && (65...90).contains(byte) ? byte + 32 : byte)
    }
    return result
}

@Test func preparedBlockSIMDAgreesWithScalarForEveryByteAndLane() {
    for caseSensitive in [false, true] {
        let query = ASCIILiteralQuery(query: .init(text: "AZ", caseSensitive: caseSensitive),
                                      maximumLength: 64)!
        for requireASCII in [false, true] {
            for byte in UInt8.min...UInt8.max {
                for lane in 0..<33 {
                    var source = [UInt8](repeating: 0x78, count: 33)
                    source[lane] = byte
                    let data = Data(source)
                    let expected = scalarPrepared(data, caseSensitive: caseSensitive,
                                                  requireASCII: requireASCII)
                    #expect(query.preparedBlock(data, requireASCII: requireASCII) == expected)
                }
            }
        }
    }
}

@Test func preparedBlockSIMDHandlesLengthsSlicesAndPunctuationEdges() {
    let punctuation = Array("@AZ[\\]`az{|}~0123456789 \t\r\n".utf8)
    for caseSensitive in [false, true] {
        let query = ASCIILiteralQuery(query: .init(text: "AZ", caseSensitive: caseSensitive),
                                      maximumLength: 64)!
        for requireASCII in [false, true] {
            for length in [0, 1, 15, 16, 17, 31, 32, 33, 47, 48, 49] {
                for prefix in [0, 1, 3, 15] {
                    let content = (0..<length).map { punctuation[$0 % punctuation.count] }
                    let storage = Data(repeating: 0xFF, count: prefix) + Data(content)
                    let slice = storage[prefix..<(prefix + length)]
                    #expect(query.preparedBlock(slice, requireASCII: requireASCII)
                            == scalarPrepared(slice, caseSensitive: caseSensitive, requireASCII: requireASCII))
                }
            }
        }
    }
}

@Test func preparedBlockRejectsHighByteInEveryVectorLaneAndTail() {
    for caseSensitive in [false, true] {
        let query = ASCIILiteralQuery(query: .init(text: "a", caseSensitive: caseSensitive),
                                      maximumLength: 64)!
        for length in [16, 17, 31, 32, 33, 48, 49] {
            for lane in 0..<length {
                var source = [UInt8](repeating: 65, count: length)
                source[lane] = lane.isMultiple(of: 2) ? 0x80 : 0xFF
                let input = Data(source)
                #expect(query.preparedBlock(input, requireASCII: true) == nil)
                if !caseSensitive { #expect(query.preparedBlock(input, requireASCII: false) == nil) }
                else { #expect(query.preparedBlock(input, requireASCII: false) == input) }
            }
        }
    }
}

private func scannedHit(_ result: ASCIILiteralScanResult<Int>) -> TextMatch<Int>? {
    if case .match(let hit) = result { return hit }
    return nil
}

@Test func darwinMemmemMatchesFoundationForSlicesAndBlockBoundaries() {
    let cases = [
        ("a", "--a--", [2, 3]),
        ("abc", "--aBc--abc--", [1, 3, 5, 7]),
        ("aaa", "aaaaa", [1, 2, 3]),
        ("needle", String(repeating: "x", count: 31) + "needle", [15, 16, 17, 31, 32]),
    ]
    for (pattern, text, partitions) in cases {
        for sensitive in [false, true] {
            let query = ASCIILiteralQuery(query: .init(text: pattern, caseSensitive: sensitive),
                                          maximumLength: 64)!
            for direction in [SearchDirection.forward, .backward] {
                for partition in partitions {
                    let bytes = Array(text.utf8)
                    var foundation = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                                              matcher: .foundation)
                    var candidate = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                                             matcher: .darwinMemmem)
                    let starts = stride(from: 0, to: bytes.count, by: partition).map { $0 }
                    let ordered = direction == .forward ? starts : starts.reversed()
                    for start in ordered {
                        let end = min(start + partition, bytes.count)
                        let storage = Data([0xFF, 0xFF, 0xFF] + bytes[start..<end])
                        let slice = storage[3..<(storage.count)]
                        let left = foundation.consume(slice, startingAt: start, requireASCII: true)
                        let right = candidate.consume(slice, startingAt: start, requireASCII: true)
                        #expect(scannedHit(left) == scannedHit(right))
                        if scannedHit(left) != nil { break }
                    }
                }
            }
        }
    }
}

@Test func darwinMemmemPreservesUnicodeFallbackBeforeApparentASCIIHit() {
    let query = ASCIILiteralQuery(query: .init(text: "ss"), maximumLength: 64)!
    let bytes = Data(Array("ßSS".utf8))
    for direction in [SearchDirection.forward, .backward] {
        var scanner = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                              matcher: .darwinMemmem)
        if case .requiresUnicode = scanner.consume(bytes, startingAt: 0, requireASCII: true) {}
        else { Issue.record("Unicode block must trigger scalar fallback") }
    }
}

@Test func simdShortMatchesFoundationAcrossLengthsSlicesAndPartitions() {
    for length in [1, 2, 6, 16, 17, 32, 33, 64] {
        let pattern = length == 1 ? "z" : "a" + String(repeating: "x", count: length - 2) + "z"
        let nearMiss = length > 2
            ? "a" + "q" + String(repeating: "x", count: length - 3) + "z"
            : String(repeating: "a", count: length)
        let texts = [
            pattern + String(repeating: "_", count: 97),
            String(repeating: "_", count: 97) + pattern,
            String(repeating: "_", count: 97),
            String(repeating: nearMiss, count: 12) + pattern,
            String(repeating: nearMiss, count: 12),
        ]
        for sensitive in [false, true] {
            let query = ASCIILiteralQuery(query: .init(text: pattern, caseSensitive: sensitive),
                                          maximumLength: 64)!
            for text in texts {
                let bytes = Array(text.utf8)
                for direction in [SearchDirection.forward, .backward] {
                    for partition in [1, 15, 16, 17, 32, 64, 128] {
                        var foundation = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                                                  matcher: .foundation)
                        var candidate = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                                                 matcher: .simdShort)
                        let starts = stride(from: 0, to: bytes.count, by: partition).map { $0 }
                        var found: TextMatch<Int>?
                        for start in direction == .forward ? starts : starts.reversed() {
                            let end = min(start + partition, bytes.count)
                            let storage = Data([0xFF, 0xFF, 0xFF] + bytes[start..<end])
                            let slice = storage[3..<storage.count]
                            #expect(slice.startIndex == 3)
                            let left = foundation.consume(slice, startingAt: start, requireASCII: true)
                            let right = candidate.consume(slice, startingAt: start, requireASCII: true)
                            #expect(scannedHit(left) == scannedHit(right))
                            found = scannedHit(left)
                            if found != nil { break }
                        }
                        let expected = Data(bytes).range(of: Data(pattern.utf8),
                                                           options: direction == .backward ? .backwards : [])
                        #expect(found?.lowerBound == expected?.lowerBound)
                        #expect(found?.upperBound == expected?.upperBound)
                    }
                }
            }
        }
    }
}

@Test func simdShortDenseNearMissesAndUnicodeFallback() {
    let query = ASCIILiteralQuery(query: .init(text: "abc"), maximumLength: 64)!
    for text in [String(repeating: "axc", count: 40) + "abc",
                 String(repeating: "axc", count: 40)] {
        let bytes = Data(text.utf8)
        var foundation = ASCIILiteralScanner<Int>(query: query, direction: .forward,
                                                  matcher: .foundation)
        var candidate = ASCIILiteralScanner<Int>(query: query, direction: .forward,
                                                 matcher: .simdShort)
        #expect(scannedHit(foundation.consume(bytes, startingAt: 0, requireASCII: true))
                == scannedHit(candidate.consume(bytes, startingAt: 0, requireASCII: true)))
    }
    for direction in [SearchDirection.forward, .backward] {
        var scanner = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                              matcher: .simdShort)
        if case .requiresUnicode = scanner.consume(Data("ßabc".utf8), startingAt: 0,
                                                   requireASCII: true) {}
        else { Issue.record("Unicode block must trigger scalar fallback") }
    }
}

@Test func simdShortFindsEarliestHitInEveryCandidateLane() {
    let query = ASCIILiteralQuery(query: .init(text: "abc", caseSensitive: true),
                                  maximumLength: 16)!
    for lane in 0..<32 {
        let text = String(repeating: "x", count: lane) + "abc"
            + String(repeating: "x", count: 64)
        let storage = Data([0xFF, 0xFF]) + Data(text.utf8)
        let slice = storage[2..<storage.count]
        var scanner = ASCIILiteralScanner<Int>(query: query, direction: .forward,
                                              matcher: .simdShort)
        #expect(scannedHit(scanner.consume(slice, startingAt: 100, requireASCII: true))?.lowerBound
                == 100 + lane)
    }
}

@Test func simdShortResumesAfterEighthRejectedCandidate() {
    let query = ASCIILiteralQuery(query: .init(text: "abc", caseSensitive: true),
                                  maximumLength: 16)!
    let nearMisses = String(repeating: "axc", count: 8)
    let text = nearMisses + "abc" + String(repeating: "x", count: 64)
    var scanner = ASCIILiteralScanner<Int>(query: query, direction: .forward,
                                          matcher: .simdShort)
    #expect(scannedHit(scanner.consume(Data(text.utf8), startingAt: 0,
                                       requireASCII: true))?.lowerBound == 24)

    var continued = ASCIILiteralScanner<Int>(query: query, direction: .forward,
                                            matcher: .simdShort)
    if case .advance = continued.consume(Data(nearMisses.utf8), startingAt: 0,
                                         requireASCII: true) {}
    else { Issue.record("near misses must not match") }
    #expect(scannedHit(continued.consume(Data(("abc" + String(repeating: "x", count: 32)).utf8),
                                         startingAt: 24, requireASCII: true))?.lowerBound == 24)
}

@Test func singlePatternACMatchesFoundationForSlicesPartitionsAndDirections() {
    let patterns = ["a", "ab", "ababac", "a" + String(repeating: "b", count: 15) + "c",
                    String(repeating: "ab", count: 16), String(repeating: "x", count: 63) + "z"]
    for pattern in patterns {
        let padding = String(repeating: "_", count: 73)
        let prefix = String(pattern.prefix(max(1, pattern.count - 1)))
        let texts: [String] = [
            pattern + padding,
            padding + pattern,
            padding,
            String(repeating: prefix, count: 4) + pattern,
            pattern + "_" + pattern,
        ]
        for sensitive in [false, true] {
            let query = ASCIILiteralQuery(query: .init(text: pattern, caseSensitive: sensitive),
                                          maximumLength: 64)!
            for text in texts {
                let bytes = Array(text.utf8)
                for direction in [SearchDirection.forward, .backward] {
                    for partition in [1, 2, 7, 15, 16, 17, 32, 64, 128] {
                        var foundation = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                                                  matcher: .foundation)
                        var candidate = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                                                 matcher: .ahoCorasick)
                        let starts = stride(from: 0, to: bytes.count, by: partition).map { $0 }
                        var found: TextMatch<Int>?
                        for start in direction == .forward ? starts : starts.reversed() {
                            let end = min(start + partition, bytes.count)
                            let storage = Data([0xFF, 0xFF, 0xFF] + bytes[start..<end])
                            let slice = storage[3..<storage.count]
                            let left = foundation.consume(slice, startingAt: start, requireASCII: true)
                            let right = candidate.consume(slice, startingAt: start, requireASCII: true)
                            #expect(scannedHit(left) == scannedHit(right))
                            found = scannedHit(left)
                            if found != nil { break }
                        }
                        let expected = Data(bytes).range(of: Data(pattern.utf8),
                                                           options: direction == .backward ? .backwards : [])
                        #expect(found?.lowerBound == expected?.lowerBound)
                        #expect(found?.upperBound == expected?.upperBound)
                    }
                }
            }
        }
    }
}

@Test func singlePatternACPreservesUnicodeFallbackAndSensitiveHighBytes() {
    let folded = ASCIILiteralQuery(query: .init(text: "ss"), maximumLength: 16)!
    for direction in [SearchDirection.forward, .backward] {
        var scanner = ASCIILiteralScanner<Int>(query: folded, direction: direction,
                                              matcher: .ahoCorasick)
        if case .requiresUnicode = scanner.consume(Data("ßSS".utf8), startingAt: 0,
                                                   requireASCII: false) {}
        else { Issue.record("Unicode block must trigger scalar fallback") }
    }
    let sensitive = ASCIILiteralQuery(query: .init(text: "abc", caseSensitive: true),
                                      maximumLength: 16)!
    let bytes = Data("éabc".utf8)
    for direction in [SearchDirection.forward, .backward] {
        var scanner = ASCIILiteralScanner<Int>(query: sensitive, direction: direction,
                                              matcher: .ahoCorasick)
        #expect(scannedHit(scanner.consume(bytes, startingAt: 0,
                                           requireASCII: false))?.lowerBound == 2)
    }
}

@Test func singlePatternACChoosesFirstOrLastOverlappingMatch() {
    for (pattern, text) in [("aaa", "aaaaa"), ("aba", "ababa")] {
        let query = ASCIILiteralQuery(query: .init(text: pattern, caseSensitive: true),
                                      maximumLength: 8)!
        for (direction, expected) in [(SearchDirection.forward, 0), (.backward, 2)] {
            var scanner = ASCIILiteralScanner<Int>(query: query, direction: direction,
                                                  matcher: .ahoCorasick)
            #expect(scannedHit(scanner.consume(Data(text.utf8), startingAt: 0,
                                               requireASCII: true))?.lowerBound == expected)
        }
    }
}
