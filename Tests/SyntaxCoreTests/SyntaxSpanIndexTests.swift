import Testing
@testable import SyntaxCore

private func capture(_ range: Range<Int>, _ kind: SyntaxKind, priority: Int = 0) -> SyntaxCapture {
    SyntaxCapture(span: SyntaxHighlightSpan(byteRange: range, kind: kind), priority: priority)
}

@Test func nestedCapturesPreserveOuterHighlightAndSubrangeLookup() {
    let index = SyntaxSpanIndex(captures: [
        capture(0..<100, .string),
        capture(10..<20, .property, priority: 1),
        capture(30..<40, .number, priority: 1),
    ])
    #expect(index.highlights(in: 0..<100) == [
        SyntaxHighlightSpan(byteRange: 0..<10, kind: .string),
        SyntaxHighlightSpan(byteRange: 10..<20, kind: .property),
        SyntaxHighlightSpan(byteRange: 20..<30, kind: .string),
        SyntaxHighlightSpan(byteRange: 30..<40, kind: .number),
        SyntaxHighlightSpan(byteRange: 40..<100, kind: .string),
    ])
    #expect(index.highlights(in: 50..<60) == [SyntaxHighlightSpan(byteRange: 40..<100, kind: .string)])
}

@Test func normalizationResolvesPartialAndExactOverlapsDeterministically() {
    let spans = SyntaxSpanNormalizer.normalize([
        capture(8..<15, .number, priority: 2),
        capture(0..<10, .string),
        capture(0..<10, .property, priority: 1),
        capture(3..<5, .comment, priority: 1), // narrower wins equal priority
        capture(3..<5, .constant, priority: 1), // earlier wins remaining ties
        capture(15..<17, .number, priority: 2), // coalesces with preceding number
        capture(19..<19, .comment, priority: 9),
    ])
    #expect(spans == [
        SyntaxHighlightSpan(byteRange: 0..<3, kind: .property),
        SyntaxHighlightSpan(byteRange: 3..<5, kind: .comment),
        SyntaxHighlightSpan(byteRange: 5..<8, kind: .property),
        SyntaxHighlightSpan(byteRange: 8..<17, kind: .number),
    ])
}

@Test func spanIndexHandlesGapsBoundariesAndEmptyRequests() {
    let index = SyntaxSpanIndex(captures: [capture(2..<4, .string), capture(6..<9, .number)])
    #expect(index.highlights(in: 0..<2).isEmpty)
    #expect(index.highlights(in: 4..<6).isEmpty)
    #expect(index.highlights(in: 9..<12).isEmpty)
    #expect(index.highlights(in: 3..<3).isEmpty)
    #expect(index.highlights(in: 3..<7).count == 2)
    #expect(SyntaxSpanIndex(captures: []).highlights(in: 0..<100).isEmpty)
}

@Test func normalizationMatchesPerByteReferenceForManyOverlaps() {
    let kinds: [SyntaxKind] = [.string, .property, .number, .comment, .constant]
    let captures = (0..<300).map { i in
        let start = (i * 37) % 200
        return capture(start..<(start + (i * 13) % 80), kinds[i % kinds.count], priority: i % 4)
    }
    let index = SyntaxSpanIndex(captures: captures)
    for byte in 0..<280 {
        let winner = captures.indices.filter { captures[$0].span.byteRange.contains(byte) }.sorted {
            let a = captures[$0], b = captures[$1]
            if a.priority != b.priority { return a.priority > b.priority }
            if a.span.byteRange.count != b.span.byteRange.count { return a.span.byteRange.count < b.span.byteRange.count }
            return $0 < $1
        }.first
        #expect(index.highlights(in: byte..<(byte + 1)).first?.kind == winner.map { captures[$0].span.kind })
    }
}
