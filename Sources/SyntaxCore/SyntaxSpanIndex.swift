/// A parser capture before overlaps have been resolved.
struct SyntaxCapture: Sendable {
    let span: SyntaxHighlightSpan
    let priority: Int
}

/// Resolves overlaps in O(n log n). Higher priority wins, then the narrower
/// capture, then the earlier input capture. Adjacent equal kinds are coalesced.
enum SyntaxSpanNormalizer {
    static func normalize(_ input: [SyntaxCapture]) -> [SyntaxHighlightSpan] {
        let captures = input.filter { !$0.span.byteRange.isEmpty }
        let starts = captures.indices.sorted {
            captures[$0].span.byteRange.lowerBound < captures[$1].span.byteRange.lowerBound
        }
        let boundaries = Set(captures.flatMap {
            [$0.span.byteRange.lowerBound, $0.span.byteRange.upperBound]
        }).sorted()
        var heap: [Int] = []
        var nextStart = 0
        var result: [SyntaxHighlightSpan] = []

        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            let a = captures[lhs], b = captures[rhs]
            if a.priority != b.priority { return a.priority > b.priority }
            if a.span.byteRange.count != b.span.byteRange.count {
                return a.span.byteRange.count < b.span.byteRange.count
            }
            return lhs < rhs
        }

        func insert(_ index: Int) {
            heap.append(index)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        func removeFirst() {
            let last = heap.removeLast()
            guard !heap.isEmpty else { return }
            heap[0] = last
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, precedes(heap[child + 1], heap[child]) { child += 1 }
                guard precedes(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                parent = child
            }
        }

        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) {
            while nextStart < starts.count,
                  captures[starts[nextStart]].span.byteRange.lowerBound <= lower {
                insert(starts[nextStart])
                nextStart += 1
            }
            // Expired entries can remain below the winner until they reach the top.
            while let first = heap.first, captures[first].span.byteRange.upperBound <= lower {
                removeFirst()
            }
            guard let winner = heap.first else { continue }
            let kind = captures[winner].span.kind
            if let last = result.last, last.kind == kind, last.byteRange.upperBound == lower {
                result[result.count - 1] = SyntaxHighlightSpan(
                    byteRange: last.byteRange.lowerBound..<upper, kind: kind)
            } else {
                result.append(SyntaxHighlightSpan(byteRange: lower..<upper, kind: kind))
            }
        }
        return result
    }
}

/// Immutable index whose normalized spans have monotonically increasing ends.
struct SyntaxSpanIndex: Sendable {
    private let spans: [SyntaxHighlightSpan]

    init(captures: [SyntaxCapture]) {
        spans = SyntaxSpanNormalizer.normalize(captures)
    }

    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] {
        guard !byteRange.isEmpty else { return [] }
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].byteRange.upperBound <= byteRange.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var result: [SyntaxHighlightSpan] = []
        while low < spans.count, spans[low].byteRange.lowerBound < byteRange.upperBound {
            result.append(spans[low])
            low += 1
        }
        return result
    }
}
