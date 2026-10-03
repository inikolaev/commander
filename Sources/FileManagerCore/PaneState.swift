import Foundation

public enum PaneRow: Sendable, Equatable {
    case parent(URL)
    case entry(FileEntry)

    public var url: URL {
        switch self {
        case .parent(let url): url
        case .entry(let entry): entry.url
        }
    }
    public var name: String {
        switch self {
        case .parent: ".."
        case .entry(let entry): entry.name
        }
    }
    public var isDirectory: Bool {
        switch self {
        case .parent: true
        case .entry(let entry): entry.isDirectory
        }
    }
}

/// Pure navigation state. A failed directory read leaves the current pane intact.
public struct PaneState: Sendable {
    public private(set) var directory: URL
    public private(set) var directoryModified: Date?
    public private(set) var rows: [PaneRow] = []
    public private(set) var selectedIndex: Int?
    /// Marked entries are independent of the keyboard cursor (selectedIndex).
    public private(set) var markedURLs: Set<URL> = []
    public var markedEntries: [FileEntry] {
        rows.compactMap { row in
            guard case .entry(let entry) = row, isMarked(row) else { return nil }
            return entry
        }
    }

    public mutating func clearMarks() {
        markedURLs.removeAll()
        endRangeSelection()
    }
    private var rangeAnchor: Int?
    private var marksBeforeRange: Set<URL> = []

    public mutating func endRangeSelection() {
        rangeAnchor = nil
        marksBeforeRange = []
    }

    public mutating func extendSelection(to index: Int) {
        guard let current = selectedIndex, rows.indices.contains(index) else { return }
        if rangeAnchor == nil { rangeAnchor = current; marksBeforeRange = markedURLs }
        let anchor = rangeAnchor ?? current
        markedURLs = marksBeforeRange
        for row in rows[min(anchor, index)...max(anchor, index)] {
            if case .entry(let entry) = row { markedURLs.insert(entry.selectionURL) }
        }
        selectedIndex = index
    }

    public mutating func toggleMarkAndAdvance() {
        toggleMark()
        if let index = selectedIndex { select(min(index + 1, rows.count - 1)) }
    }

    public func isMarked(_ row: PaneRow) -> Bool {
        guard case .entry(let entry) = row else { return false }
        return markedURLs.contains(entry.selectionURL)
    }

    public mutating func toggleMark() {
        endRangeSelection()
        guard let row = selectedRow, case .entry(let entry) = row else { return }
        let url = entry.selectionURL
        if !markedURLs.insert(url).inserted { markedURLs.remove(url) }
    }

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public var selectedRow: PaneRow? {
        guard let selectedIndex, rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    public var parent: URL? {
        let candidate = directory.deletingLastPathComponent().standardizedFileURL
        return candidate.path == directory.path ? nil : candidate
    }

    public mutating func select(_ index: Int) {
        endRangeSelection()
        selectedIndex = rows.indices.contains(index) ? index : nil
    }

    public mutating func replace(directory: URL, entries: [FileEntry], preferredSelection: URL? = nil, directoryModified: Date? = nil) {
        endRangeSelection()
        let sameDirectory = self.directory == directory.standardizedFileURL
        let oldEntries = rows.compactMap { row -> FileEntry? in
            if case .entry(let entry) = row { return entry }
            return nil
        }
        let byURL = Dictionary(entries.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { first, _ in first })
        let byIdentity = Dictionary(grouping: entries, by: \.identity)
        let oldByIdentity = Dictionary(grouping: oldEntries, by: \.identity)
        func matchingURL(for old: FileEntry) -> URL? {
            let atSamePath = byURL[old.url.standardizedFileURL]
            if let identity = old.identity {
                // A path disambiguates unchanged hard links; otherwise only follow an unambiguous identity.
                if atSamePath?.identity == identity { return atSamePath?.url }
                if oldByIdentity[identity]?.count == 1, let matches = byIdentity[identity], matches.count == 1 {
                    return matches[0].url
                }
            }
            // Preserve path-based behavior for atomic saves and filesystems without identifiers.
            return atSamePath?.url
        }
        var selection = preferredSelection
        if sameDirectory {
            if let preferredSelection,
               let old = oldEntries.first(where: { $0.url.standardizedFileURL == preferredSelection.standardizedFileURL }) {
                selection = matchingURL(for: old)
            }
            markedURLs = Set(oldEntries.filter { markedURLs.contains($0.selectionURL) }
                .compactMap { matchingURL(for: $0)?.standardizedFileURL })
        } else {
            markedURLs.removeAll()
        }
        self.directory = directory.standardizedFileURL
        self.directoryModified = directoryModified
        rows = (parent.map { [PaneRow.parent($0)] } ?? []) + entries.map(PaneRow.entry)
        selectedIndex = selection.flatMap { preferred in
            rows.firstIndex { $0.url.standardizedFileURL == preferred.standardizedFileURL }
        } ?? (rows.isEmpty ? nil : 0)
    }
}
