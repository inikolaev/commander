import Testing
import TextSearchCore

@Test func maximumMatchSpanAccountsForFoldExpansion() {
    #expect(TextSearchQuery(text: "ß").maximumMatchSourceScalars == 2)
    #expect(TextSearchQuery(text: "ß", caseSensitive: true).maximumMatchSourceScalars == 1)
    #expect(TextSearchQuery(text: "ss").maximumMatchSourceScalars == 2)
}

@Test func literalQueryPreservesInputAndOptions() {
    let query = TextSearchQuery(text: " a\n", caseSensitive: true, wholeWord: true)
    #expect(query.text == " a\n")
    #expect(query.caseSensitive)
    #expect(query.wholeWord)
    #expect(!query.isEmpty)
    #expect(TextSearchQuery(text: "").isEmpty)
    #expect(!TextSearchQuery(text: " ").isEmpty)
}

@Test func queryEqualityUsesExactScalarsAndOptions() {
    let composed = TextSearchQuery(text: "\u{00E9}")
    let decomposed = TextSearchQuery(text: "e\u{0301}")
    #expect(composed != decomposed)
    #expect(composed == TextSearchQuery(text: "\u{00E9}"))
    #expect(composed != TextSearchQuery(text: "\u{00E9}", caseSensitive: true))
    #expect(composed != TextSearchQuery(text: "\u{00E9}", wholeWord: true))
}

@Test func matchRangeIsNonemptyAndHalfOpen() {
    let viewer = TextMatch<Int64>(lowerBound: 4_294_967_296, upperBound: 4_294_967_299)
    #expect(viewer?.lowerBound == 4_294_967_296)
    #expect(viewer?.upperBound == 4_294_967_299)
    #expect(TextMatch<Int>(lowerBound: 0, upperBound: 1) != nil)
    #expect(TextMatch<Int>(lowerBound: -1, upperBound: 1) == nil)
    #expect(TextMatch<Int>(lowerBound: 1, upperBound: 1) == nil)
    #expect(TextMatch<Int>(lowerBound: 2, upperBound: 1) == nil)
}
