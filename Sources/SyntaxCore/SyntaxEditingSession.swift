import Foundation
import SwiftTreeSitter
import TreeSitter

/// A replacement in UTF-16 coordinates of the document immediately before it.
/// Deltas in a batch are applied in order, as with EditorContentDelta.
public struct SyntaxEditingDelta: Sendable {
    public let range: NSRange
    public let insertedText: String

    public init(range: NSRange, insertedText: String) {
        self.range = range
        self.insertedText = insertedText
    }
}

public enum SyntaxEditingError: Error {
    case invalidRange
}

/// Owns mutable parser state. Returned highlighters are immutable, Sendable snapshots.
public actor SyntaxEditingSession {
    private let definition: TreeSitterSyntaxDefinition?
    private let registry: SyntaxRegistry
    private let fallbackHighlighter: (@Sendable (Data, SyntaxRegistry) throws -> any SyntaxHighlighter)?
    private let maximumFileSize: Int
    private var source: Data
    private var lines: UTF8LineIndex
    private var parser: Parser?
    private var tree: MutableTree?
    private var snapshot: any SyntaxHighlighter = PlainTextSyntaxHighlighter.shared

    init(source: Data, definition: TreeSitterSyntaxDefinition?, registry: SyntaxRegistry,
         maximumFileSize: Int,
         fallbackHighlighter: (@Sendable (Data, SyntaxRegistry) throws -> any SyntaxHighlighter)? = nil) {
        self.source = source
        self.lines = UTF8LineIndex(source)
        self.definition = definition
        self.registry = registry
        self.fallbackHighlighter = fallbackHighlighter
        self.maximumFileSize = max(0, maximumFileSize)
        guard source.count <= maximumFileSize else { return }
        guard let definition else {
            if let fallbackHighlighter {
                self.snapshot = (try? fallbackHighlighter(source, registry)) ?? PlainTextSyntaxHighlighter.shared
            }
            return
        }
        do {
            let parser = Parser()
            try parser.setLanguage(definition.language)
            guard let tree = Self.parse(parser: parser, source: source, oldTree: nil) else { return }
            self.snapshot = TreeSitterSyntaxHighlighter(index: try TreeSitterSyntaxHighlighter.makeIndex(
                source: source, tree: tree, definition: definition, registry: registry))
            self.parser = parser
            self.tree = tree
        } catch { /* Highlighting is optional. */ }
    }

    public func highlighter() -> any SyntaxHighlighter { snapshot }

    /// Applies an atomic, ordered batch. Invalid UTF-16 boundaries leave the session unchanged.
    @discardableResult
    public func apply(_ deltas: [SyntaxEditingDelta]) throws -> any SyntaxHighlighter {
        guard !deltas.isEmpty else { return snapshot }
        var nextSource = source
        var nextLines = lines
        var edits: [InputEdit] = []
        for delta in deltas {
            guard delta.range.location != NSNotFound, delta.range.location >= 0,
                  delta.range.length >= 0,
                  delta.range.location <= Int.max - delta.range.length,
                  let start = nextLines.location(delta.range.location, in: nextSource),
                  let end = nextLines.location(delta.range.location + delta.range.length, in: nextSource),
                  start.byte <= end.byte else { throw SyntaxEditingError.invalidRange }
            let inserted = Data(delta.insertedText.utf8)
            let newEndPoint: Point
            if let lastNewline = inserted.lastIndex(of: 10) {
                let rowDelta = inserted.filter { $0 == 10 }.count
                newEndPoint = Point(row: Int(start.point.row) + rowDelta,
                                    column: inserted.count - lastNewline - 1)
            } else {
                newEndPoint = Point(row: Int(start.point.row),
                                    column: Int(start.point.column) + inserted.count)
            }
            edits.append(InputEdit(startByte: start.byte, oldEndByte: end.byte,
                                   newEndByte: start.byte + inserted.count,
                                   startPoint: start.point, oldEndPoint: end.point,
                                   newEndPoint: newEndPoint))
            nextSource.replaceSubrange(start.byte..<end.byte, with: inserted)
            nextLines.replace(start: start.byte, oldEnd: end.byte, inserted: inserted,
                              removedUTF16: delta.range.length,
                              insertedUTF16: (delta.insertedText as NSString).length,
                              newSource: nextSource)
        }
        source = nextSource
        lines = nextLines
        guard nextSource.count <= maximumFileSize else {
            parser = nil
            tree = nil
            snapshot = PlainTextSyntaxHighlighter.shared
            return snapshot
        }
        guard let definition else {
            snapshot = (try? fallbackHighlighter?(nextSource, registry)) ?? PlainTextSyntaxHighlighter.shared
            return snapshot
        }
        do {
            let parser = try parser ?? Self.newParser(definition)
            let oldTree = tree
            if let oldTree { for edit in edits { oldTree.edit(edit) } }
            guard let nextTree = Self.parse(parser: parser, source: nextSource, oldTree: oldTree)
                ?? Self.parse(parser: parser, source: nextSource, oldTree: nil) else {
                throw SyntaxHighlightingError.parseFailed
            }
            let index = try TreeSitterSyntaxHighlighter.makeIndex(
                source: nextSource, tree: nextTree, definition: definition, registry: registry)
            self.parser = parser
            self.tree = nextTree
            snapshot = TreeSitterSyntaxHighlighter(index: index)
        } catch {
            // A failed incremental parse or query must not expose stale spans.
            parser = nil
            tree = nil
            snapshot = PlainTextSyntaxHighlighter.shared
        }
        return snapshot
    }

    private static func newParser(_ definition: TreeSitterSyntaxDefinition) throws -> Parser {
        let parser = Parser()
        try parser.setLanguage(definition.language)
        return parser
    }

    private static func parse(parser: Parser, source: Data, oldTree: MutableTree?) -> MutableTree? {
        parser.parse(tree: oldTree, encoding: TSInputEncodingUTF8, readBlock: { offset, _ in
            guard offset < source.count else { return nil }
            return source.subdata(in: offset..<min(source.count, offset + 64 * 1024))
        })
    }
}

private struct UTF8LineIndex {
    private struct Line {
        var byte: Int
        var utf16: Int
    }
    private var starts: [Line] = [Line(byte: 0, utf16: 0)]

    init(_ source: Data) { scan(source, from: 0, through: source.count, baseUTF16: 0) }

    func location(_ utf16: Int, in source: Data) -> (byte: Int, point: Point)? {
        guard utf16 >= 0 else { return nil }
        var low = 0, high = starts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if starts[middle].utf16 <= utf16 { low = middle } else { high = middle }
        }
        let line = starts[low]
        var byte = line.byte, units = line.utf16
        while units < utf16 && byte < source.count {
            let first = source[byte]
            let width = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
            let step = width == 4 ? 2 : 1
            guard byte + width <= source.count, units + step <= utf16 else { return nil }
            byte += width
            units += step
        }
        guard units == utf16 else { return nil }
        return (byte, Point(row: low, column: byte - line.byte))
    }

    mutating func replace(start: Int, oldEnd: Int, inserted: Data,
                          removedUTF16: Int, insertedUTF16: Int, newSource: Data) {
        let first = line(atByte: start)
        var low = first + 1, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle].byte <= oldEnd { low = middle + 1 } else { high = middle }
        }
        let next: Int? = low < starts.count ? low : nil
        let byteShift = inserted.count - (oldEnd - start)
        let oldBoundary = next.map { starts[$0].byte } ?? newSource.count - byteShift
        let newBoundary = oldBoundary + byteShift
        let base = starts[first]
        let unitShift = insertedUTF16 - removedUTF16
        let suffix = (next.map { Array(starts[($0 + 1)...]) } ?? []).map {
            Line(byte: $0.byte + byteShift, utf16: $0.utf16 + unitShift)
        }
        starts = Array(starts[...first])
        scan(newSource, from: base.byte, through: newBoundary, baseUTF16: base.utf16)
        starts.append(contentsOf: suffix)
    }

    private func line(atByte byte: Int) -> Int {
        var low = 0, high = starts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if starts[middle].byte <= byte { low = middle } else { high = middle }
        }
        return low
    }

    private mutating func scan(_ source: Data, from lower: Int, through upper: Int, baseUTF16: Int) {
        var units = baseUTF16
        var byte = lower
        while byte < upper {
            let first = source[byte]
            let width = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
            units += width == 4 ? 2 : 1
            byte += width
            if first == 10 { starts.append(Line(byte: byte, utf16: units)) }
        }
    }

}
