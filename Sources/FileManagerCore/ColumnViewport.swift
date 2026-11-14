/// A column-major viewport: entries run down each column before continuing right.
/// Kept independent of drawing so resize, paging, and selection visibility are testable.
public struct ColumnViewport: Sendable {
    public private(set) var firstIndex = 0
    public private(set) var rowsPerColumn = 1
    public let columnCount = 2
    public var capacity: Int { rowsPerColumn * columnCount }

    public init() {}

    public mutating func resize(rows: Int, selectedIndex: Int?, itemCount: Int) {
        rowsPerColumn = max(1, rows)
        firstIndex = (firstIndex / rowsPerColumn) * rowsPerColumn
        reveal(selectedIndex, itemCount: itemCount)
    }

    public mutating func reveal(_ selectedIndex: Int?, itemCount: Int) {
        guard itemCount > 0 else { firstIndex = 0; return }
        let lastColumnStart = ((itemCount - 1) / rowsPerColumn) * rowsPerColumn
        firstIndex = min(firstIndex, lastColumnStart)
        guard let index = selectedIndex, (0..<itemCount).contains(index) else { return }
        if index < firstIndex {
            firstIndex = (index / rowsPerColumn) * rowsPerColumn
        } else if index >= firstIndex + capacity {
            firstIndex = (index / rowsPerColumn - columnCount + 1) * rowsPerColumn
        }
    }

    /// Put a distant search hit in the leading column, leaving neighboring files visible.
    public mutating func revealSearchResult(_ index: Int, itemCount: Int) {
        guard (0..<itemCount).contains(index),
              index < firstIndex || index >= firstIndex + capacity else { return }
        firstIndex = (index / rowsPerColumn) * rowsPerColumn
    }

    public func index(column: Int, row: Int, itemCount: Int) -> Int? {
        guard (0..<columnCount).contains(column), (0..<rowsPerColumn).contains(row) else { return nil }
        let index = firstIndex + column * rowsPerColumn + row
        return index < itemCount ? index : nil
    }

    public func movedIndex(from index: Int?, by delta: Int, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        return max(0, min(itemCount - 1, (index ?? 0) + delta))
    }
}
