import Testing
import TextSearchCore

private typealias Input = TextSearchInput<Int>

private func inputs(_ text: String) -> [Input] {
    var result: [Input] = []
    var offset = 0
    for scalar in text.unicodeScalars {
        let width = String(scalar).utf16.count
        result.append(.scalar(TextSearchScalar(
            value: scalar, lowerBound: offset, upperBound: offset + width
        )!))
        offset += width
    }
    return result
}

private func scan(
    _ source: [Input],
    _ query: TextSearchQuery,
    direction: SearchDirection = .forward,
    partition: Int = .max
) -> [TextMatch<Int>] {
    guard var machine = LiteralSearchMachine<Int>(query: query, direction: direction) else {
        return []
    }
    var hits: [TextMatch<Int>] = []
    let ordered = direction == .forward ? source : source.reversed()
    var cursor = ordered.startIndex
    while cursor < ordered.endIndex {
        let end = ordered.index(cursor, offsetBy: partition, limitedBy: ordered.endIndex)
            ?? ordered.endIndex
        for input in ordered[cursor..<end] {
            switch machine.consume(input) {
            case .match(let hit): hits.append(hit)
            case .advance: break
            case .cancelled: Issue.record("Unexpected cancellation")
            }
        }
        cursor = end
    }
    if case .match(let hit) = machine.finish() { hits.append(hit) }
    return hits
}

private func bounds(_ hits: [TextMatch<Int>]) -> [[Int]] {
    hits.map { [$0.lowerBound, $0.upperBound] }
}

@Test func emptyQueryHasNoMachine() {
    #expect(LiteralSearchMachine<Int>(
        query: TextSearchQuery(text: ""), direction: .forward
    ) == nil)
}

@Test func overlapsAndReverseParity() {
    let source = inputs("aaaaa")
    let query = TextSearchQuery(text: "aaa", caseSensitive: true)
    let expected = [[0, 3], [1, 4], [2, 5]]
    #expect(bounds(scan(source, query)) == expected)
    #expect(bounds(scan(source, query, direction: .backward)) == expected.reversed())
}

@Test func partitionsDoNotChangeCrossBoundaryMatches() {
    let source = inputs("xababaßcat\u{200D}dog!ababa")
    for query in [
        TextSearchQuery(text: "aba", caseSensitive: true),
        TextSearchQuery(text: "bass", caseSensitive: false),
        TextSearchQuery(text: "cat", wholeWord: true),
        TextSearchQuery(text: "dog", wholeWord: true),
        TextSearchQuery(text: "ababa", caseSensitive: true),
    ] {
        let forward = bounds(scan(source, query))
        let backward = bounds(scan(source, query, direction: .backward))
        #expect(backward == forward.reversed())
        for partition in 1...source.count {
            #expect(bounds(scan(source, query, partition: partition)) == forward)
            #expect(bounds(scan(source, query, direction: .backward, partition: partition)) == backward)
        }
    }
}

@Test func fullFoldHonorsOriginalScalarBoundaries() {
    let source = inputs("Straße STRASSE ﬁ İ ς Σ")
    #expect(bounds(scan(source, TextSearchQuery(text: "STRASSE"))) == [[0, 6], [7, 14]])
    #expect(bounds(scan(inputs("ß"), TextSearchQuery(text: "ss"))) == [[0, 1]])
    #expect(scan(inputs("ß"), TextSearchQuery(text: "s")).isEmpty)
    #expect(bounds(scan(inputs("ﬁ"), TextSearchQuery(text: "fi"))) == [[0, 1]])
    #expect(scan(inputs("ﬁ"), TextSearchQuery(text: "f")).isEmpty)
    #expect(bounds(scan(inputs("İ"), TextSearchQuery(text: "i\u{0307}"))) == [[0, 1]])
    #expect(scan(inputs("İ"), TextSearchQuery(text: "i")).isEmpty)
    #expect(bounds(scan(inputs("ς Σ"), TextSearchQuery(text: "σ"))) == [[0, 1], [2, 3]])
    #expect(bounds(scan(inputs("ßß"), TextSearchQuery(text: "ss"))) == [[0, 1], [1, 2]])
    #expect(bounds(scan(inputs("ßß"), TextSearchQuery(text: "ssss", wholeWord: true))) == [[0, 2]])
    #expect(scan(inputs("ßß"), TextSearchQuery(text: "sss")).isEmpty)
}

@Test func cyrillicExtendedCaseFoldingUsesPinnedUnicodeTable() {
    let variants = ["ᲀ", "ᲁ", "ᲂ", "ᲃ", "ᲄ", "ᲅ", "ᲆ", "ᲇ", "ᲈ"]
    let folded = ["в", "д", "о", "с", "т", "т", "ъ", "ѣ", "ꙋ"]
    for (variant, regular) in zip(variants, folded) {
        #expect(bounds(scan(inputs(variant), TextSearchQuery(text: regular))) == [[0, 1]])
        #expect(bounds(scan(inputs(regular), TextSearchQuery(text: variant))) == [[0, 1]])
        #expect(bounds(scan(inputs(variant), TextSearchQuery(text: regular), direction: .backward)) == [[0, 1]])
        #expect(scan(inputs(variant), TextSearchQuery(text: regular, caseSensitive: true)).isEmpty)
    }
}

@Test func sensitiveAndCanonicalSemantics() {
    #expect(scan(inputs("é"), TextSearchQuery(text: "e\u{0301}")).isEmpty)
    #expect(scan(inputs("e\u{0301}"), TextSearchQuery(text: "é")).isEmpty)
    #expect(scan(inputs("A"), TextSearchQuery(text: "a", caseSensitive: true)).isEmpty)
    #expect(bounds(scan(inputs("A"), TextSearchQuery(text: "a"))) == [[0, 1]])
}

@Test func wholeWordUsesSourceNeighborsAcrossInputs() {
    let source = inputs("foo foo_bar (foo) 1foo foo\u{0301} foo\u{200D}bar foo")
    let query = TextSearchQuery(text: "foo", caseSensitive: true, wholeWord: true)
    let forward = bounds(scan(source, query))
    #expect(forward == [[0, 3], [13, 16], [36, 39]])
    #expect(bounds(scan(source, query, direction: .backward)) == forward.reversed())
    let barred = inputs("foo") + [.barrier] + inputs("foo").map { input -> Input in
        if case .scalar(let scalar) = input {
            return .scalar(TextSearchScalar(
                value: scalar.value,
                lowerBound: scalar.lowerBound + 3,
                upperBound: scalar.upperBound + 3
            )!)
        }
        return .barrier
    }
    #expect(bounds(scan(barred, query)) == [[0, 3], [3, 6]])
}

@Test func sourceSpansRemainExactAcrossMultiUnitScalars() {
    let source = inputs("a😀b")
    let query = TextSearchQuery(text: "😀b", caseSensitive: true)
    #expect(bounds(scan(source, query)) == [[1, 4]])
    #expect(bounds(scan(source, query, direction: .backward)) == [[1, 4]])

    let lf = "\n".unicodeScalars.first!
    let crlfToken = TextSearchScalar(value: lf, lowerBound: 1, upperBound: 3)!
    let a = TextSearchScalar(value: "a".unicodeScalars.first!, lowerBound: 0, upperBound: 1)!
    let b = TextSearchScalar(value: "b".unicodeScalars.first!, lowerBound: 3, upperBound: 4)!
    let crlfSource: [Input] = [.scalar(a), .scalar(crlfToken), .scalar(b)]
    #expect(bounds(scan(crlfSource, TextSearchQuery(text: "a\nb", caseSensitive: true))) == [[0, 4]])
}

@Test func barriersPreventCrossRunMatches() {
    let source = inputs("ab") + [.barrier] + inputs("cd").map { input -> Input in
        guard case .scalar(let scalar) = input else { return .barrier }
        return .scalar(TextSearchScalar(
            value: scalar.value,
            lowerBound: scalar.lowerBound + 3,
            upperBound: scalar.upperBound + 3
        )!)
    }
    #expect(scan(source, TextSearchQuery(text: "abcd", caseSensitive: true)).isEmpty)
    #expect(bounds(scan(source, TextSearchQuery(text: "cd", caseSensitive: true))) == [[3, 5]])
}

@Test func cancellationIsCheckedDuringNoHitScan() {
    var machine = LiteralSearchMachine<Int>(
        query: TextSearchQuery(text: "needle", caseSensitive: true),
        direction: .forward
    )!
    let scalar = TextSearchScalar(value: "x".unicodeScalars.first!, lowerBound: 0, upperBound: 1)!
    var checks = 0
    var cancelled = false
    for _ in 0..<10_000 {
        let step = machine.consume(.scalar(scalar), isCancelled: {
            checks += 1
            return checks == 3
        })
        if case .cancelled = step { cancelled = true; break }
    }
    #expect(cancelled)
    #expect(machine.processedUnits == 512)
    #expect(checks == 3)
    if case .cancelled = machine.finish() {} else { Issue.record("Finish must stay cancelled") }
}
