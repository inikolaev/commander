import AppKit
import Foundation
import Testing
import FileManagerCore
import SyntaxCore
@testable import CommanderUI

@Test @MainActor func viewerShiftF2SelectsWordWrapping() throws {
    _ = NSApplication.shared
    let viewer = TerminalFileViewer(path: "sample.txt")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = viewer
    var selectedWordWrap = false
    viewer.onInput = { input in
        if case .toggleWrapType = input { selectedWordWrap = true }
    }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .shift, timestamp: 1, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 120))
    viewer.keyDown(with: event)
    #expect(selectedWordWrap)
}

@Test @MainActor func viewerDisplaysFilePagesAndRestoresFocusOnEscape() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try (1...100).map { "Line \($0): read-only viewer" }.joined(separator: "\n").write(to: url, atomically: false, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileViewerCoordinator()
    var closed = false
    coordinator.onClose = { closed = true }
    coordinator.present(url: url, window: window)
    #expect(coordinator.view == nil)
    #expect(window.firstResponder === pane)
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    #expect(viewer.page?.lines.first?.text == "Line 1: read-only viewer")
    #expect(window.firstResponder === viewer)
    coordinator.request(.end)
    for _ in 0..<200 {
        if viewer.page?.lines.last?.text == "Line 100: read-only viewer" { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.lines.last?.text == "Line 100: read-only viewer")
    if let output = ProcessInfo.processInfo.environment["COMMANDER_VIEWER_RENDER_PATH"] {
        let bitmap = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
    let f4 = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 118))
    viewer.keyDown(with: f4)
    for _ in 0..<200 {
        if viewer.page?.mode == .hex { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.mode == .hex)
    #expect(viewer.page?.lines.first?.text.contains(": ") == true)
    if let output = ProcessInfo.processInfo.environment["COMMANDER_HEX_RENDER_PATH"] {
        let bitmap = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
        viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
    viewer.keyDown(with: f4)
    for _ in 0..<200 {
        if viewer.page?.mode == .text { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.mode == .text)
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
    viewer.keyDown(with: escape)
    #expect(closed)
    #expect(coordinator.view == nil)
    #expect(window.firstResponder === pane)
}

@Test @MainActor func viewerSearchKeysRevealAndDismissWithoutClosing() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("first\nneedle\nlast needle\n".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: url, window: window)
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    viewer.keyDown(with: try key(98)) // F7
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.page?.offset == 6 && viewer.page?.lines.first?.searchColumns.count == 6 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.offset == 6)
    #expect(viewer.page?.lines.first?.searchColumns.map(\.lowerBound) == Array(0..<6))
    viewer.keyDown(with: try key(98, .shift)) // Shift-F7
    for _ in 0..<200 {
        if viewer.page?.offset == 13 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.offset == 13)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
        location: viewer.convert(NSPoint(x: 20, y: TerminalTheme.lineHeight * 2), to: nil),
        modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    viewer.mouseDown(with: click)
    #expect(window.firstResponder === viewer)
    viewer.keyDown(with: try key(53)) // Escape from content while search remains open
    #expect(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.isEmpty)
    #expect(coordinator.view === viewer)
    #expect(window.firstResponder === viewer)
    coordinator.close()
}

@Test @MainActor func oversizedUnwrappedViewerRecoversToWrappedMode() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var bytes = Data(repeating: 0x78, count: 16 * 1024 * 1024 + 4)
    bytes.append(0x0A)
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: url, window: window)
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    coordinator.toggleWrap()
    for _ in 0..<200 {
        if viewer.wrapsText { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(coordinator.view === viewer)
    #expect(viewer.wrapsText)
    coordinator.close()
}

@Test @MainActor func viewerSearchHitSurvivesModeAndWrapSwitches() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data((String(repeating: "x", count: 900) + "needle\n").utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: url, window: window)
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    coordinator.toggleWrap()
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.activeSearchRange?.lowerBound == 900 && viewer.horizontalOffset > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.horizontalOffset > 0)
    coordinator.toggleMode()
    for _ in 0..<200 {
        if viewer.page?.mode == .hex { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.mode == .hex)
    #expect(viewer.page?.lines.first?.offset == 896)
    #expect(viewer.page?.lines.first?.searchColumns.count == 12)
    coordinator.toggleMode()
    for _ in 0..<200 {
        if viewer.page?.mode == .text { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.mode == .text)
    #expect(viewer.horizontalOffset > 0)
    coordinator.toggleWrap()
    for _ in 0..<200 {
        if viewer.wrapsText && viewer.page?.lines.first?.offset ?? 0 > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.lines.first?.offset ?? 0 > 0)
    #expect(viewer.activeSearchRange?.lowerBound == 900)
    coordinator.close()
}

private actor MutableViewerTestSource: FileContentSource {
    var data: Data
    var revision: UInt64 = 1
    var metadataCalls = 0
    var mutationCall: Int?
    var replacement: Data?
    var pauseRevealRead = false
    var pausePageRead = false
    var readBlocked = false
    var readContinuation: CheckedContinuation<Void, Never>?
    init(_ text: String) { data = Data(text.utf8) }
    func metadata() -> ContentMetadata {
        metadataCalls += 1
        if metadataCalls == mutationCall, let replacement {
            data = replacement
            revision += 1
            mutationCall = nil
        }
        return ContentMetadata(size: Int64(data.count), revision: revision)
    }
    func length() -> Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) async -> Data {
        if pausePageRead && offset == 0 {
            pausePageRead = false
            readBlocked = true
            await withCheckedContinuation { readContinuation = $0 }
        }
        if pauseRevealRead && offset >= 4_000 && count < 1_000 {
            pauseRevealRead = false
            readBlocked = true
            await withCheckedContinuation { readContinuation = $0 }
        }
        let start = Int(offset)
        guard start < data.count else { return Data() }
        return data[start..<min(data.count, start + count)]
    }
    func replace(_ text: String) { data = Data(text.utf8); revision += 1 }
    func mutateOnSixthMetadata(_ text: String) {
        mutationCall = metadataCalls + 6
        replacement = Data(text.utf8)
    }
    func armRevealPause() { pauseRevealRead = true }
    func armPagePause() { pausePageRead = true }
    func isReadBlocked() -> Bool { readBlocked }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
}

@Test @MainActor func viewerSearchBarReducesPagingByObscuredRows() throws {
    _ = NSApplication.shared
    let viewer = TerminalFileViewer(path: "/tmp/test.txt")
    viewer.frame = NSRect(x: 0, y: 0, width: 780, height: 400)
    let fullRows = viewer.visibleRows
    viewer.searchActive = true
    #expect(viewer.visibleRows < fullRows)
    var requestedScroll: Int?
    viewer.onInput = { input in
        if case .navigate(.scroll(let rows)) = input { requestedScroll = rows }
    }
    let pageDown = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 121))
    viewer.keyDown(with: pageDown)
    #expect(requestedScroll == viewer.visibleRows)
}

@Test @MainActor func viewerContinuationClearsStaleHighlightAfterSourceMutation() async throws {
    _ = NSApplication.shared
    let source = MutableViewerTestSource("needle\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt",
                        window: window, openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.activeSearchRange == 0..<6 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.activeSearchRange == 0..<6)
    await source.replace("xxxxxx\n")
    surface.onContinue?(.forward)
    for _ in 0..<200 {
        if viewer.activeSearchRange == nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.activeSearchRange == nil)
    #expect(viewer.visibleSearchColumns(forRow: 0).isEmpty)
    coordinator.close()
}

@Test @MainActor func viewerRefreshInvalidatesSameSizeEditedHit() async throws {
    _ = NSApplication.shared
    let source = MutableViewerTestSource("needle\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt", window: window,
                        openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.activeSearchRange != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.activeSearchRange == 0..<6)
    await source.replace("xxxxxx\n")
    coordinator.request(.stay)
    for _ in 0..<200 {
        if viewer.page?.revision == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.revision == 2)
    #expect(viewer.activeSearchRange == nil)
    #expect(viewer.page?.lines.first?.searchColumns.isEmpty == true)
    #expect(coordinator.view === viewer)
    coordinator.close()
}

@Test @MainActor func viewerDoesNotDrawStaleProjectionAfterValidationRace() async throws {
    _ = NSApplication.shared
    let source = MutableViewerTestSource("needle\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt",
                        window: window, openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.activeSearchRange == 0..<6 && !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.visibleSearchColumns(forRow: 0).count == 6)
    await source.mutateOnSixthMetadata("xxxxxx\n")
    coordinator.request(.stay)
    for _ in 0..<200 {
        if viewer.page?.revision == 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.revision == 2)
    #expect(viewer.activeSearchRange == nil)
    #expect(viewer.page?.lines.first?.searchColumns.count == 6)
    #expect(viewer.visibleSearchColumns(forRow: 0).isEmpty)
    coordinator.close()
}

private actor ResolvingViewerTestSource: FileContentSource {
    let data: Data
    var known = false
    init(_ text: String) { data = Data(text.utf8) }
    func metadata() -> ContentMetadata {
        ContentMetadata(size: known ? Int64(data.count) : nil, revision: 1)
    }
    func length() -> Int64 { known = true; return Int64(data.count) }
    func read(at offset: Int64, count: Int) -> Data {
        let start = Int(offset)
        guard start < data.count else { known = true; return Data() }
        let end = min(data.count, start + count)
        if end - start < count { known = true }
        return data[start..<end]
    }
}

@Test @MainActor func viewerUnknownSizeResolutionRetainsActiveHit() async throws {
    _ = NSApplication.shared
    let source = ResolvingViewerTestSource(String(repeating: "x\n", count: 5_000) + "needle\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt",
                        window: window, openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    #expect(viewer.page?.fileSize == nil)
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.page?.offset == 10_000 && viewer.page?.fileSize != nil &&
           viewer.activeSearchRange?.lowerBound == 10_000 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.fileSize == 10_007)
    #expect(viewer.page?.offset == 10_000)
    #expect(viewer.activeSearchRange?.lowerBound == 10_000)
    #expect(!viewer.visibleSearchColumns(forRow: 0).isEmpty)
    coordinator.close()
}

@Test @MainActor func viewerFreshQueryHitSurvivesOldPageRevision() async throws {
    _ = NSApplication.shared
    let source = MutableViewerTestSource("xxxxxx\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt",
                        window: window, openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    #expect(viewer.page?.revision == 1)
    await source.replace("needle\n")
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.page?.revision == 2 && viewer.activeSearchRange == 0..<6 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.revision == 2)
    #expect(viewer.activeSearchRange == 0..<6)
    #expect(viewer.visibleSearchColumns(forRow: 0).count == 6)
    coordinator.close()
}

@Test @MainActor func viewerDismissedSearchDoesNotCompletePausedReveal() async throws {
    _ = NSApplication.shared
    let source = MutableViewerTestSource(String(repeating: "x\n", count: 2_000) + "needle\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt",
                        window: window, openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    await source.armRevealPause()
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if await source.isReadBlocked() { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await source.isReadBlocked())
    #expect(viewer.page?.offset == 0)
    surface.dismissAndRestoreFocus()
    await source.releaseRead()
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.offset == 0)
    #expect(!viewer.searchActive)
    #expect(viewer.activeSearchRange == nil)
    coordinator.close()
}

@Test @MainActor func viewerManualScrollSupersedesPausedSearchReveal() async throws {
    _ = NSApplication.shared
    let source = MutableViewerTestSource(String(repeating: "x\n", count: 2_000) + "needle\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt",
                        window: window, openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    await source.armRevealPause()
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if await source.isReadBlocked() { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await source.isReadBlocked())
    #expect(viewer.page?.offset == 0)
    coordinator.request(.scroll(1))
    await source.releaseRead()
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.offset == 2)
    #expect(viewer.activeSearchRange == nil)
    coordinator.close()
}

@Test @MainActor func viewerDismissalDropsRevealQueuedBehindPageRead() async throws {
    _ = NSApplication.shared
    let source = MutableViewerTestSource(String(repeating: "x\n", count: 2_000) + "needle\n")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: URL(fileURLWithPath: "/tmp/test.txt"), displayPath: "/tmp/test.txt",
                        window: window, openSource: { source })
    for _ in 0..<200 {
        if coordinator.view != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let viewer = try #require(coordinator.view)
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    await source.armPagePause()
    coordinator.request(.stay)
    for _ in 0..<200 {
        if await source.isReadBlocked() { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await source.isReadBlocked())
    coordinator.openSearch()
    let surface = try #require(viewer.subviews.compactMap { $0 as? DocumentSearchSurface }.first)
    surface.onQueryChange?(DocumentSearchQuery(text: "needle"))
    for _ in 0..<200 {
        if viewer.activeSearchRange?.lowerBound == 4_000 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.activeSearchRange?.lowerBound == 4_000)
    surface.dismissAndRestoreFocus()
    await source.releaseRead()
    for _ in 0..<200 {
        if !coordinator.isBusy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(viewer.page?.offset == 0)
    #expect(!viewer.searchActive)
    #expect(viewer.activeSearchRange == nil)
    coordinator.close()
}

@Test @MainActor func failedViewerOpenKeepsPanesVisibleAndRestoresFocus() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    window.makeFirstResponder(pane)
    let coordinator = FileViewerCoordinator()
    var closed = false
    coordinator.onClose = { closed = true }
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    coordinator.present(url: missing, window: window)
    #expect(coordinator.view == nil)
    for _ in 0..<200 {
        #expect(coordinator.view == nil)
        if pane.subviews.contains(where: { $0 is TerminalOperationDialog }) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let dialog = try #require(pane.subviews.compactMap { $0 as? TerminalOperationDialog }.first)
    #expect(!pane.subviews.contains(where: { $0 is TerminalFileViewer }))
    dialog.onDismiss?()
    #expect(closed)
    #expect(window.firstResponder === pane)
    #expect(pane.subviews.isEmpty)
}

@Test @MainActor func closingPendingViewerDoesNotPresentItLater() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let pane = TerminalPaneView(name: "Test")
    window.contentView = pane
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("hello".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let coordinator = FileViewerCoordinator()
    coordinator.present(url: url, window: window)
    coordinator.close()
    try await Task.sleep(for: .milliseconds(100))
    #expect(coordinator.view == nil)
    #expect(pane.subviews.isEmpty)
}

@Test @MainActor func viewerMouseSelectionCopiesDisplayedText() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try "abcdefghijklm\nsecond line\nthird".write(to: url, atomically: false, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 10)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let viewer = TerminalFileViewer(path: url.path)
    window.contentView = viewer
    viewer.update(page)
    let cell = ("a" as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
    func mouse(_ type: NSEvent.EventType, row: Int, column: Int) throws -> NSEvent {
        let point = viewer.convert(NSPoint(x: 1 + CGFloat(column) * cell,
            y: CGFloat(row + 1) * TerminalTheme.lineHeight + 4), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, column: 2))
    viewer.mouseDragged(with: try mouse(.leftMouseDragged, row: 1, column: 6))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 1, column: 6))
    #expect(window.firstResponder === viewer)
    #expect(viewer.selectedText == "cdefghijklm\nsecond")
    let copy = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    viewer.keyDown(with: copy)
    #expect(NSPasteboard.general.string(forType: .string) == viewer.selectedText)

    // Backward drags produce the same ordered text, and unchanged refreshes retain selection.
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 1, column: 6))
    viewer.mouseDragged(with: try mouse(.leftMouseDragged, row: 0, column: 2))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, column: 2))
    viewer.update(page)
    #expect(viewer.selectedText == "cdefghijklm\nsecond")
    #expect(NSApp.sendAction(#selector(TerminalFileViewer.copy(_:)), to: viewer, from: nil))
    #expect(NSPasteboard.general.string(forType: .string) == viewer.selectedText)

    // Clicking clears selection; copying nothing leaves the clipboard intact.
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, column: 2))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, column: 2))
    #expect(viewer.selectedText.isEmpty)
    viewer.keyDown(with: copy)
    #expect(NSPasteboard.general.string(forType: .string) == "cdefghijklm\nsecond")

    viewer.wrapsText = false
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    viewer.keyDown(with: right)
    #expect(viewer.horizontalOffset == 1)
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, column: 0))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, column: 3))
    #expect(viewer.selectedText == "bcd")

    let controlRight = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    viewer.keyDown(with: controlRight)
    #expect(viewer.horizontalOffset == 21)
    viewer.update(try await document.page(.scroll(1), rows: 10))
    #expect(viewer.selectedText.isEmpty)
}

@Test @MainActor func viewerSelectionPreservesComposedCharactersAndEmptyLines() async throws {
    _ = NSApplication.shared
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = "A😀e\u{301}Z"
    try (first + "\n\nlast").write(to: url, atomically: false, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 10)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let viewer = TerminalFileViewer(path: url.path)
    window.contentView = viewer
    viewer.update(page)
    func mouse(_ type: NSEvent.EventType, row: Int, prefix: String) throws -> NSEvent {
        let width = (prefix as NSString).size(withAttributes: [.font: TerminalTheme.font]).width
        let point = viewer.convert(NSPoint(x: 1 + width, y: CGFloat(row + 1) * TerminalTheme.lineHeight + 4), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, prefix: "A"))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 0, prefix: "A😀e\u{301}"))
    #expect(viewer.selectedText == "😀e\u{301}")
    viewer.mouseDown(with: try mouse(.leftMouseDown, row: 0, prefix: "A"))
    viewer.mouseUp(with: try mouse(.leftMouseUp, row: 2, prefix: "la"))
    #expect(viewer.selectedText == "😀e\u{301}Z\n\nla")
    // Render with an active selection to exercise highlighting too.
    let bitmap = try #require(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
    viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
    viewer.update(try await document.page(rows: 10, mode: .hex))
    #expect(viewer.selectedText.isEmpty)
}


private struct TestSyntaxHighlighter: SyntaxHighlighter {
    let isActive = true
    let spans: [SyntaxHighlightSpan]

    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] {
        spans.filter {
            $0.byteRange.lowerBound < byteRange.upperBound
                && $0.byteRange.upperBound > byteRange.lowerBound
        }
    }
}

@Test func viewerSyntaxProjectionPreservesTokenAcrossReadBoundary() async throws {
    let start = 4096 - 13
    let line = "          const index = +e.target.dataset.index;"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
    try Data((String(repeating: "x", count: start - 1) + "\n" + line + "\nnext\n").utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let highlighter = TestSyntaxHighlighter(spans: [
        SyntaxHighlightSpan(byteRange: 4093..<4098, kind: .keyword)
    ])
    for command in [ViewerCommand.home, .end] {
        let document = try FileViewerDocument(url: url)
        let page = try await document.page(command, rows: commandIsHome(command) ? 200 : 2,
                                           wrapColumns: 80, includeSourceText: true)
        let index = try #require(page.lines.firstIndex(where: { $0.offset == start }))
        #expect(page.lines[index].text == line)
        #expect(ViewerSyntaxProjection.make(page: page, highlighter: highlighter).lines[index] == [
            ViewerDisplayHighlight(range: 10..<15, kind: .keyword)
        ])
    }
}

private func commandIsHome(_ command: ViewerCommand) -> Bool {
    if case .home = command { true } else { false }
}

@Test func viewerSyntaxProjectionMergesSourceAndSpansSequentially() async throws {
    let source = "\t\"é\": true\n"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(source.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 1, includeSourceText: true)
    let bytes = Array(source.utf8)
    let quoteStart = try #require(bytes.firstIndex(of: 34))
    let colon = try #require(bytes.firstIndex(of: 58))
    let trueStart = colon + 2
    let highlighter = TestSyntaxHighlighter(spans: [
        SyntaxHighlightSpan(byteRange: quoteStart..<colon, kind: .property),
        SyntaxHighlightSpan(byteRange: trueStart..<(trueStart + 4), kind: .constant),
    ])

    let projection = ViewerSyntaxProjection.make(page: page, highlighter: highlighter)
    let line = try #require(projection.lines.first)
    #expect(line == [
        ViewerDisplayHighlight(range: 4..<7, kind: .property),
        ViewerDisplayHighlight(range: 9..<13, kind: .constant),
    ])
}

@Test func viewerSyntaxProjectionHandlesManySpansOnOneLogicalLine() async throws {
    let fields = (0..<5_000).map { "\"k\($0)\":\($0)" }
    let source = "{" + fields.joined(separator: ",") + "}\n"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(source.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = try FileViewerDocument(url: url)
    let page = try await document.page(rows: 1, includeSourceText: true)
    var spans: [SyntaxHighlightSpan] = []
    var cursor = 1
    for index in 0..<5_000 {
        let key = "\"k\(index)\""
        let keyEnd = cursor + key.utf8.count
        spans.append(SyntaxHighlightSpan(byteRange: cursor..<keyEnd, kind: .property))
        cursor = keyEnd + 1
        let value = String(index)
        let valueEnd = cursor + value.utf8.count
        spans.append(SyntaxHighlightSpan(byteRange: cursor..<valueEnd, kind: .number))
        cursor = valueEnd + (index == 4_999 ? 0 : 1)
    }

    let projection = ViewerSyntaxProjection.make(
        page: page,
        highlighter: TestSyntaxHighlighter(spans: spans)
    )
    #expect(projection.lines.count == 1)
    #expect(projection.lines[0].count == 10_000)
    #expect(projection.lines[0].first?.range == 1..<5)
    #expect(projection.lines[0].last?.kind == .number)
}

@Test func viewerSyntaxProjectionClipsMultilineJSONCommentAcrossWrappedPages() async throws {
    let source = "/*ab\ncafé\tXYZ and more*/"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    let data = Data(source.utf8)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let highlighter = SyntaxRegistry.viewer.highlighter(for: url, data: data)
    #expect(highlighter.isActive)

    var page = try await document.page(rows: 2, wrapColumns: 6, includeSourceText: true)
    var seenOffsets = Set<Int64>()
    while seenOffsets.insert(page.offset).inserted {
        let projection = ViewerSyntaxProjection.make(page: page, highlighter: highlighter)
        #expect(projection.lines.count == page.lines.count)
        for (line, spans) in zip(page.lines, projection.lines) {
            #expect(spans == [ViewerDisplayHighlight(range: 0..<line.text.count, kind: .comment)])
        }
        page = try await document.page(.scroll(1), rows: 2, wrapColumns: 6, includeSourceText: true)
    }
    #expect(seenOffsets.count > 2)
    let hexPage = try await document.page(rows: 2, mode: .hex, includeSourceText: true)
    #expect(ViewerSyntaxProjection.make(page: hexPage, highlighter: highlighter).lines.allSatisfy { $0.isEmpty })
}

@Test func viewerSyntaxProjectionClipsPythonMultilineStringAcrossWrappedPages() async throws {
    let source = "\"\"\"hé\nworld\tinside\nend\"\"\""
    let data = Data(source.utf8)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = try FileViewerDocument(url: url)
    let highlighter = SyntaxRegistry.viewer.highlighter(for: url)
    #expect(highlighter.isActive)
    var page = try await document.page(rows: 2, wrapColumns: 6, includeSourceText: true)
    var seenOffsets = Set<Int64>()
    while seenOffsets.insert(page.offset).inserted {
        let projection = ViewerSyntaxProjection.make(page: page, highlighter: highlighter)
        for (line, spans) in zip(page.lines, projection.lines) {
            #expect(spans == [ViewerDisplayHighlight(range: 0..<line.text.count, kind: .string)])
        }
        page = try await document.page(.scroll(1), rows: 2, wrapColumns: 6, includeSourceText: true)
    }
    #expect(seenOffsets.count > 2)
}

@Test func viewerSyntaxProjectionClipsEmbeddedCommentsAcrossWrappedPages() async throws {
    for tag in ["script", "style"] {
        let prefix = "<p>hé😀</p>\n<\(tag)>\n"
        let comment = "/*hé\nworld\tinside\nend*/"
        let source = prefix + comment + "\n</\(tag)>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".html")
        let data = Data(source.utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try FileViewerDocument(url: url)
        let highlighter = SyntaxRegistry.viewer.highlighter(for: url, data: data)
        #expect(highlighter.isActive)
        var page = try await document.page(rows: 2, wrapColumns: 6, includeSourceText: true)
        var seenOffsets = Set<Int64>()
        var commentRows = Set<Int64>()
        while seenOffsets.insert(page.offset).inserted {
            let projection = ViewerSyntaxProjection.make(page: page, highlighter: highlighter)
            for (line, spans) in zip(page.lines, projection.lines) {
                if line.offset >= prefix.utf8.count && line.offset < prefix.utf8.count + comment.utf8.count {
                    commentRows.insert(line.offset)
                    #expect(spans == [ViewerDisplayHighlight(range: 0..<line.text.count, kind: .comment)])
                }
            }
            page = try await document.page(.scroll(1), rows: 2, wrapColumns: 6, includeSourceText: true)
        }
        #expect(commentRows.count >= 4)
    }
}
