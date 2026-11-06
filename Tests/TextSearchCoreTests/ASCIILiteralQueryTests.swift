import Foundation
import Testing
import TextSearchCore

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
