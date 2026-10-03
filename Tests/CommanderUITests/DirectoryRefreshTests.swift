import AppKit
import FileManagerCore
import Foundation
import Testing
@testable import CommanderUI

@MainActor
private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
    for _ in 0..<250 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(predicate(), "Pane did not synchronize with the filesystem", sourceLocation: sourceLocation)
}

@Test @MainActor func panesObserveExternalChangesAndKeepSelection() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let selected = directory.appendingPathComponent("selected.txt")
    try Data("original".utf8).write(to: selected)
    let panes = (0..<2).map { PaneViewController(title: "Pane \($0)", directory: directory, reader: LocalDirectoryReader()) }
    for pane in panes { pane.load(directory, preferredSelection: selected) }
    try await eventually { panes.allSatisfy { !$0.isLoading && $0.state.selectedRow?.name == "selected.txt" } }
    for pane in panes {
        (pane.view as? TerminalPaneView)?.onInput?(.toggleMark)
    }
    let added = directory.appendingPathComponent("added.txt")
    try Data().write(to: added)
    try await eventually { panes.allSatisfy { $0.state.rows.contains { $0.name == "added.txt" } } }
    for pane in panes {
        #expect(pane.state.selectedRow?.name == "selected.txt")
        #expect(pane.state.markedURLs.contains(selected.standardizedFileURL))
    }
    // An in-place content write must update metadata even without a directory entry change.
    let handle = try FileHandle(forWritingTo: selected)
    try handle.write(contentsOf: Data(repeating: 65, count: 100))
    try handle.close()
    try await eventually {
        panes.allSatisfy { pane in
            pane.state.rows.contains { row in
                if case .entry(let entry) = row { return entry.name == "selected.txt" && entry.size == 100 }
                return false
            }
        }
    }
    let renamed = directory.appendingPathComponent("renamed.txt")
    try fm.moveItem(at: added, to: renamed)
    try await eventually {
        panes.allSatisfy { pane in
            pane.state.rows.contains { $0.name == "renamed.txt" } && !pane.state.rows.contains { $0.name == "added.txt" }
        }
    }
    let renamedSelection = directory.appendingPathComponent("renamed-selection.txt")
    try fm.moveItem(at: selected, to: renamedSelection)
    try await eventually {
        panes.allSatisfy { $0.state.selectedRow?.name == "renamed-selection.txt"
            && $0.state.markedURLs == [renamedSelection.standardizedFileURL] }
    }
    try fm.removeItem(at: renamedSelection)
    try await eventually { panes.allSatisfy { !$0.state.rows.contains { $0.name == "renamed-selection.txt" } && $0.state.markedURLs.isEmpty } }
}

@Test @MainActor func monitoringFollowsNavigationAndSurvivesFailedNavigation() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    try fm.createDirectory(at: first, withIntermediateDirectories: true)
    try fm.createDirectory(at: second, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let pane = PaneViewController(title: "Pane", directory: first, reader: LocalDirectoryReader())
    pane.load(first)
    try await eventually { !pane.isLoading }
    try Data().write(to: first.appendingPathComponent("old.txt"))
    pane.load(second)
    try await eventually { !pane.isLoading && pane.state.directory.path == second.path }
    try Data().write(to: second.appendingPathComponent("new.txt"))
    try await eventually { pane.state.rows.contains { $0.name == "new.txt" } }
    #expect(!pane.state.rows.contains { $0.name == "old.txt" })
    pane.load(root.appendingPathComponent("missing"))
    try await eventually { !pane.isLoading }
    #expect(pane.state.directory.path == second.path)
    try Data().write(to: second.appendingPathComponent("after-failure.txt"))
    try await eventually { pane.state.rows.contains { $0.name == "after-failure.txt" } }
}

private final class ActivationReader: DirectoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [FileEntry] = []
    func setEntries(_ entries: [FileEntry]) { lock.lock(); defer { lock.unlock() }; self.entries = entries }
    func entries(at directory: URL, showHidden: Bool) throws -> [FileEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

@Test @MainActor func activationRefreshesWithoutFilesystemEvents() async throws {
    _ = NSApplication.shared
    let directory = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let reader = ActivationReader()
    let pane = PaneViewController(title: "Pane", directory: directory, reader: reader)
    pane.load(directory)
    try await eventually { !pane.isLoading }
    reader.setEntries([FileEntry(url: directory.appendingPathComponent("new.txt"), name: "new.txt",
        isDirectory: false, isSymbolicLink: false, size: 0, modified: nil)])
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    try await eventually { pane.state.rows.contains { $0.name == "new.txt" } }
}
