import AppKit
import GhosttyTerminal

/// AppKit owns the scrollbar animation; Ghostty owns the rendered content.
@MainActor
final class TerminalScrollView: NSScrollView {
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    var onScrollToRow: ((UInt) -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?
    private var scrollbar: TerminalScrollbar?
    private var synchronizing = false
    private var rowHeight: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        documentView = DocumentView()
        verticalScroller?.setAccessibilityLabel("Terminal scrollback")
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification, object: contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ scrollbar: TerminalScrollbar) {
        let moved = self.scrollbar.map { $0.total == scrollbar.total && $0.offset != scrollbar.offset } ?? false
        self.scrollbar = scrollbar
        synchronizeGeometry()
        if moved, !isHidden { flashScrollers() }
    }

    override func layout() {
        super.layout()
        synchronizeGeometry()
    }

    private func synchronizeGeometry() {
        guard !synchronizing, let scrollbar, scrollbar.len > 0, let documentView else { return }
        synchronizing = true
        defer { synchronizing = false }
        rowHeight = contentSize.height / CGFloat(scrollbar.len)
        verticalLineScroll = rowHeight
        documentView.setFrameSize(NSSize(width: contentSize.width,
            height: CGFloat(max(scrollbar.total, scrollbar.len)) * rowHeight))
        let maximum = scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0
        contentView.scroll(to: NSPoint(x: 0, y: CGFloat(min(scrollbar.offset, maximum)) * rowHeight))
        reflectScrolledClipView(contentView)
    }

    @objc private func didScroll(_ notification: Notification) {
        guard !synchronizing, !isHidden, rowHeight > 0, let scrollbar, scrollbar.total > scrollbar.len else { return }
        let row = min(CGFloat(scrollbar.total - scrollbar.len), max(0, (contentView.bounds.minY / rowHeight).rounded()))
        onScrollToRow?(UInt(row))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), let scroller = verticalScroller,
              hit === scroller || hit.isDescendant(of: scroller) else { return nil }
        return hit
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
    }
}
