import AppKit
import Testing
@testable import Commander

@Test func paneUsesEveryFullRowAboveFooter() {
    for height in 200...700 {
        let geometry = PaneGeometry(bounds: NSRect(x: 0, y: 0, width: 540, height: height), lineHeight: 18)
        let last = geometry.cell(column: 0, row: geometry.rowsPerColumn - 1)
        let gap = geometry.separatorY - last.maxY
        #expect(gap >= geometry.listBottomPadding)
        #expect(gap < geometry.lineHeight + geometry.listBottomPadding)
    }
    // Ten rows plus the minimum footer gap fit at 262 points.
    for (height, rows) in [(261, 9), (262, 10), (269, 10), (279, 10), (280, 11)] {
        let geometry = PaneGeometry(bounds: NSRect(x: 0, y: 0, width: 540, height: height), lineHeight: 18)
        #expect(geometry.rowsPerColumn == rows)
    }
}

@Test @MainActor func panesFillWindowAtDifferentSizes() throws {
    _ = NSApplication.shared
    let controller = CommanderWindowController()
    let window = try #require(controller.window)
    let root = try #require(window.contentViewController)
    let panes = root.children.compactMap { $0 as? PaneViewController }
    #expect(panes.count == 2)
    for size in [NSSize(width: 700, height: 380), NSSize(width: 1080, height: 700), NSSize(width: 1500, height: 900)] {
        window.setContentSize(size)
        root.view.layoutSubtreeIfNeeded()
        let left = panes[0].view.frame
        let right = panes[1].view.frame
        #expect(abs(left.minX - 2) < 1)
        #expect(abs(right.maxX - (root.view.bounds.width - 2)) < 1)
        #expect(abs(left.width - right.width) < 1)
        #expect(abs(right.minX - left.maxX - 2) < 1)
        #expect(left.height > size.height - 130)
        #expect(abs(left.height - right.height) < 1)
        for pane in panes {
            let terminal = try #require(pane.view as? TerminalPaneView)
            #expect(terminal.subviews.isEmpty)
            #expect(terminal.geometry.rowsPerColumn > 5)
            let cell = terminal.geometry.cell(column: 1, row: 3)
            let position = try #require(terminal.geometry.position(at: NSPoint(x: cell.midX, y: cell.midY)))
            #expect(position.column == 1)
            #expect(position.row == 3)
            #expect(terminal.geometry.position(at: NSPoint(x: 10, y: 0)) == nil)
        }
    }
}
