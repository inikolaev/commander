import AppKit
import Testing
@testable import CommanderUI

private func searchKey(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: text,
        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
}

@Test @MainActor func documentSearchKeyMapChecksModifiersBeforeF7() throws {
    _ = NSApplication.shared
    #expect(DocumentSearchKeyAction.action(for: try searchKey("", code: 98), searchActive: false) == .focus)
    #expect(DocumentSearchKeyAction.action(for: try searchKey("", code: 98, flags: .shift), searchActive: false) == .forward)
    #expect(DocumentSearchKeyAction.action(for: try searchKey("", code: 98, flags: .option), searchActive: false) == .backward)
    #expect(DocumentSearchKeyAction.action(for: try searchKey("f", code: 3, flags: .command), searchActive: false) == .focus)
    #expect(DocumentSearchKeyAction.action(for: try searchKey("g", code: 5, flags: .command), searchActive: true) == .forward)
    #expect(DocumentSearchKeyAction.action(for: try searchKey("g", code: 5, flags: [.command, .shift]), searchActive: true) == .backward)
    #expect(DocumentSearchKeyAction.action(for: try searchKey("", code: 53), searchActive: true) == .dismiss)
    #expect(DocumentSearchKeyAction.action(for: try searchKey("", code: 53), searchActive: false) == .none)
}

@Test @MainActor func documentSearchWrapAndContinuationUseExactStart() async {
    let positions = [2, 4, 6]
    let controller = DocumentSearchController<Int, Int, Int>(
        origin: 4, revision: { 1 }, hitStart: { $0 },
        wrapStart: { direction in direction == .forward ? 0 : 9 },
        scan: { _, direction, anchor, limit, _ in
            let hit = direction == .forward
                ? positions.first(where: { $0 >= anchor && (limit == nil || $0 < limit!) })
                : positions.last(where: { $0 <= anchor && (limit == nil || $0 > limit!) })
            return hit.map(DocumentSearchScanResult.found) ?? .exhausted
        })
    controller.open(at: 4)
    controller.setQuery(DocumentSearchQuery(text: "x"))
    await waitForSearch { controller.activeHit == 4 }
    controller.continueSearch(.forward)
    await waitForSearch { controller.activeHit == 6 }
    controller.continueSearch(.forward)
    await waitForSearch { controller.activeHit == 2 }
    #expect(controller.status == .found(wrapped: true))
    controller.continueSearch(.backward)
    await waitForSearch { controller.activeHit == 6 }
    #expect(controller.status == .found(wrapped: true))
    controller.close()
}

private actor SearchScanProbe {
    private(set) var intervals: [(Int, Int?)] = []
    private(set) var visitedStarts = 0

    func record(anchor: Int, limit: Int?, count: Int) {
        intervals.append((anchor, limit))
        visitedStarts += count
    }

    func snapshot() -> ([(Int, Int?)], Int) { (intervals, visitedStarts) }
}

@Test @MainActor func documentSearchNoHitWrapScansDisjointStartIntervals() async {
    let probe = SearchScanProbe()
    let controller = DocumentSearchController<Int, Int, Int>(
        origin: 700, revision: { 1 }, hitStart: { $0 }, wrapStart: { _ in 0 },
        scan: { _, _, anchor, limit, _ in
            let end = limit ?? 1_000
            await probe.record(anchor: anchor, limit: limit, count: max(0, end - anchor))
            return .exhausted
        })
    controller.open(at: 700)
    controller.setQuery(DocumentSearchQuery(text: "absent"))
    await waitForSearch { controller.status == .noMatches }
    let (intervals, count) = await probe.snapshot()
    #expect(intervals.count == 2)
    #expect(intervals[0].0 == 700 && intervals[0].1 == nil)
    #expect(intervals[1].0 == 0 && intervals[1].1 == 700)
    #expect(count == 1_000)
    controller.close()
}

@Test @MainActor func documentSearchSingleResultWrapReturnsSameHit() async {
    let controller = DocumentSearchController<Int, Int, Int>(
        origin: 4, revision: { 1 }, hitStart: { $0 }, wrapStart: { _ in 0 },
        scan: { _, _, anchor, limit, _ in
            anchor <= 4 && (limit == nil || 4 < limit!) ? .found(4) : .exhausted
        })
    controller.open(at: 4)
    controller.setQuery(DocumentSearchQuery(text: "only"))
    await waitForSearch { controller.activeHit == 4 }
    controller.continueSearch(.forward)
    await waitForSearch { controller.status == .found(wrapped: true) }
    #expect(controller.activeHit == 4)
    controller.close()
}

private actor SearchAvailability {
    var hasMatch = true
    func removeMatch() { hasMatch = false }
}

@Test @MainActor func documentSearchClearsHitWhenContinuationFindsNoMatches() async {
    let availability = SearchAvailability()
    let controller = DocumentSearchController<Int, Int, Int>(
        origin: 0, revision: { 1 }, hitStart: { $0 }, wrapStart: { _ in 0 },
        scan: { _, _, _, _, _ in
            let hasMatch = await availability.hasMatch
            return hasMatch ? .found(4) : .exhausted
        })
    controller.open(at: 0)
    controller.setQuery(DocumentSearchQuery(text: "needle"))
    await waitForSearch { controller.activeHit == 4 }
    await availability.removeMatch()
    controller.continueSearch(.forward)
    await waitForSearch { controller.status == .noMatches }
    #expect(controller.activeHit == nil)
    controller.close()
}

@Test @MainActor func documentSearchFencesCancelledAndLateProgress() async {
    let (started, startedContinuation) = AsyncStream<Void>.makeStream()
    var startedIterator = started.makeAsyncIterator()
    let controller = DocumentSearchController<Int, Int, Int>(
        origin: 0, revision: { 1 }, hitStart: { $0 }, wrapStart: { _ in 0 },
        scan: { query, _, _, _, progress in
            if query.text == "old" {
                startedContinuation.yield()
                try? await Task.sleep(for: .milliseconds(80))
                progress(0.8)
                return .found(1) // Deliberately ignores cancellation.
            }
            return .found(2)
        })
    controller.open(at: 0)
    controller.setQuery(DocumentSearchQuery(text: "old"))
    _ = await startedIterator.next()
    controller.setQuery(DocumentSearchQuery(text: "new"))
    await waitForSearch { controller.activeHit == 2 }
    try? await Task.sleep(for: .milliseconds(120))
    #expect(controller.activeHit == 2)
    #expect(controller.status == .found(wrapped: false))
    controller.dismiss()
    #expect(controller.status == .idle)
}

@Test @MainActor func documentSearchMutationAndDismissAdvanceStamp() async {
    var version = 1
    let controller = DocumentSearchController<Int, Int, Int>(
        origin: 0, revision: { version }, hitStart: { $0 }, wrapStart: { _ in 0 },
        scan: { _, _, _, _, _ in
            try? await Task.sleep(for: .milliseconds(50))
            return .found(3)
        })
    controller.open(at: 0)
    let firstSession = controller.stamp.session
    controller.setQuery(DocumentSearchQuery(text: "x"))
    let generation = controller.stamp.generation
    version = 2
    controller.documentDidChange(origin: 7)
    #expect(controller.stamp.generation > generation)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(controller.activeHit == nil)
    #expect(controller.status == .idle)
    controller.dismiss()
    controller.open(at: 7)
    #expect(controller.stamp.session != firstSession)
    controller.close()
}

@Test @MainActor func documentSearchSurfaceRestoresContentFocus() {
    _ = NSApplication.shared
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = content
    let responder = NSButton(title: "Content", target: nil, action: nil)
    responder.frame = NSRect(x: 0, y: 0, width: 100, height: 30)
    content.addSubview(responder)
    window.makeFirstResponder(responder)
    let surface = DocumentSearchSurface(frame: NSRect(x: 0, y: 40, width: 600, height: 32))
    content.addSubview(surface)
    surface.focus(contentResponder: responder)
    #expect(window.firstResponder !== responder)
    surface.dismissAndRestoreFocus()
    #expect(window.firstResponder === responder)
    #expect(surface.superview == nil)
}

@Test @MainActor func documentSearchSurfacePreservesScalarExactQuery() throws {
    _ = NSApplication.shared
    let surface = DocumentSearchSurface(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
    let field = try #require(surface.subviews.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable }))
    field.stringValue = "e\u{301}"
    surface.update(query: DocumentSearchQuery(text: "\u{00E9}"))
    #expect(field.stringValue.unicodeScalars.elementsEqual("\u{00E9}".unicodeScalars))
}

@Test @MainActor func documentSearchEscapeLetsIMECancelMarkedTextFirst() throws {
    _ = NSApplication.shared
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    let window = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = content
    let surface = DocumentSearchSurface(frame: NSRect(x: 0, y: 40, width: 600, height: 32))
    content.addSubview(surface)
    let field = try #require(surface.subviews.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable }))
    surface.focus(contentResponder: content)
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    #expect(!surface.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(surface.superview === content)
    _ = field.performKeyEquivalent(with: try searchKey("", code: 53))
    #expect(surface.superview === content)
    editor.unmarkText()
    #expect(surface.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(surface.superview == nil)
}

@MainActor private func waitForSearch(_ predicate: () -> Bool) async {
    for _ in 0..<100 where !predicate() {
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(predicate())
}
