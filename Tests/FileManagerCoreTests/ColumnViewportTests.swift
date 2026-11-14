import Testing
@testable import FileManagerCore

@Test func columnViewportMapsCellsAndRejectsBlankSpace() {
    var viewport = ColumnViewport()
    viewport.resize(rows: 10, selectedIndex: 0, itemCount: 15)
    #expect(viewport.index(column: 0, row: 9, itemCount: 15) == 9)
    #expect(viewport.index(column: 1, row: 0, itemCount: 15) == 10)
    #expect(viewport.index(column: 1, row: 5, itemCount: 15) == nil)
    #expect(viewport.index(column: 2, row: 0, itemCount: 15) == nil)
}

@Test func viewportKeepsSelectionVisibleWhenPagingAndResizing() {
    var viewport = ColumnViewport()
    viewport.resize(rows: 10, selectedIndex: 25, itemCount: 50)
    #expect(viewport.firstIndex == 10)
    viewport.resize(rows: 4, selectedIndex: 25, itemCount: 50)
    #expect((viewport.firstIndex..<viewport.firstIndex + viewport.capacity).contains(25))
    viewport.reveal(0, itemCount: 50)
    #expect(viewport.firstIndex == 0)
    viewport.reveal(49, itemCount: 50)
    #expect((viewport.firstIndex..<viewport.firstIndex + viewport.capacity).contains(49))
    viewport.resize(rows: 100, selectedIndex: 49, itemCount: 50)
    #expect(viewport.firstIndex == 0)
}

@Test func movementClampsToListingAndEmptyFoldersResetViewport() {
    var viewport = ColumnViewport()
    #expect(viewport.movedIndex(from: 0, by: -1, itemCount: 3) == 0)
    #expect(viewport.movedIndex(from: 2, by: 5, itemCount: 3) == 2)
    #expect(viewport.movedIndex(from: nil, by: 1, itemCount: 0) == nil)
    viewport.resize(rows: 3, selectedIndex: 29, itemCount: 30)
    viewport.reveal(nil, itemCount: 0)
    #expect(viewport.firstIndex == 0)
}

@Test func distantSearchResultScrollsIntoLeadingColumn() {
    var viewport = ColumnViewport()
    viewport.resize(rows: 10, selectedIndex: 0, itemCount: 80)
    viewport.revealSearchResult(47, itemCount: 80)
    #expect(viewport.firstIndex == 40)
    #expect(viewport.index(column: 0, row: 7, itemCount: 80) == 47)
    viewport.resize(rows: 10, selectedIndex: 47, itemCount: 80)
    #expect(viewport.firstIndex == 40)
    viewport.revealSearchResult(52, itemCount: 80) // Already visible; avoid unnecessary jumps.
    #expect(viewport.firstIndex == 40)
}
