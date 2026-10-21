import Foundation
import Darwin

public enum ViewerMode: Sendable { case text, hex }

public enum ViewerCommand: Sendable {
    case stay, scroll(Int), home, end
}

public struct ViewerLine: Sendable {
    public let offset: Int64
    public let endOffset: Int64
    public let text: String
    public let sourceText: String?

}

public struct ViewerPage: Sendable {
    public let lines: [ViewerLine]
    public let offset: Int64
    public let endOffset: Int64
    public let fileSize: Int64?
    public let mode: ViewerMode
}

public enum FileViewerError: LocalizedError {
    case notRegularFile
    case lineTooLong
    case symbolicLinkUnavailable(path: String, target: String, reason: String)
    public var errorDescription: String? {
        switch self {
        case .notRegularFile: "The viewer can only open regular files."
        case .lineTooLong: "This line exceeds the 16 MiB text limit. Use wrapped text or hex viewing."
        case let .symbolicLinkUnavailable(path, target, reason):
            "Cannot open symbolic link \(path) → \(target). \(reason)"
        }
    }
}

/// A UTF-8 text reader over an asynchronous content source, with no whole-file line index.
/// Wrapped mode advances by display width, while unwrapped mode preserves actual
/// newline-delimited logical lines so disabling wrap never invents visible rows.
public actor FileViewerDocument {
    private let source: any FileContentSource
    private static let readChunkSize = 4096
    private static let maximumTextRowBytes = 16 * 1024 * 1024
    private static let reverseScanLimit: Int64 = 65_536
    private struct TextContext {
        let revision: UInt64?
        let fileSize: Int64?
        let columns: Int?

        func sourceMatches(revision newRevision: UInt64?, fileSize newSize: Int64?) -> Bool {
            guard revision == newRevision else { return false }
            // Resolving a previously unknown length does not change content.
            return fileSize == newSize || (revision != nil && fileSize == nil && newSize != nil)
        }

        func matches(_ new: TextContext) -> Bool {
            columns == new.columns && sourceMatches(revision: new.revision, fileSize: new.fileSize)
        }
    }
    private var size: Int64 = 0
    private var sizeKnown = true
    private var top: Int64 = 0
    private var mode: ViewerMode = .text
    private var savedTextTop: Int64 = 0
    private var lastTextContext: TextContext?
    private var rowNavigation = ViewerRowNavigation()
    private var paging = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(url: URL) throws { source = try LocalFileContentSource(url: url) }
    public init(source: any FileContentSource) { self.source = source }

    private func acquirePage() async {
        if paging { await withCheckedContinuation { waiters.append($0) } }
        else { paging = true }
    }
    private func releasePage() {
        if waiters.isEmpty { paging = false }
        else { waiters.removeFirst().resume() }
    }

    private func refreshSize() async throws -> ContentMetadata {
        let metadata = try await source.metadata()
        if let reported = metadata.size {
            sizeKnown = true
            size = reported
        } else if metadata.revision != nil, lastTextContext?.revision == metadata.revision,
                  let resolved = lastTextContext?.fileSize {
            // This version was resolved by a prior End or EOF read.
            sizeKnown = true
            size = resolved
        } else {
            sizeKnown = false
            size = Int64.max
        }
        return metadata
    }

    /// Only a parsing buffer: source implementations decide what to cache/reuse.
    private func bytes(at offset: Int64, count: Int) async throws -> [UInt8] {
        try Task.checkCancellation()
        guard offset >= 0, offset < size, count > 0 else { return [] }
        let amount = Int(min(Int64(count), size - offset))
        let data = try await source.read(at: offset, count: amount)
        if data.count < amount { size = try await source.length(); sizeKnown = true }
        return Array(data)
    }

    private func byte(at offset: Int64) async throws -> UInt8? {
        try await bytes(at: offset, count: 1).first
    }

    private func wrappedReadLimit(at offset: Int64, columns: Int) -> Int64 {
        guard offset >= 0, offset < size else { return max(0, min(offset, size)) }
        // Every scalar currently occupies at least one column and uses at most
        // four UTF-8 bytes. Two more bytes cover CRLF after an exactly full row.
        let width = max(1, columns)
        let budget = width > Self.maximumTextRowBytes / 4
            ? Self.maximumTextRowBytes + 2 : 4 * width + 2
        return offset + min(Int64(budget), size - offset)
    }

    private func readRow(at offset: Int64, columns: Int? = nil, includeSourceText: Bool = false) async throws
        -> (text: String, sourceText: String?, contentEnd: Int64, next: Int64) {
        let limit = columns.map { wrappedReadLimit(at: offset, columns: $0) } ?? size
        var cursor = offset
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.readChunkSize + 4)
        while cursor < limit {
            let chunk = try await self.bytes(at: cursor, count: Int(min(Int64(Self.readChunkSize), limit - cursor)))
            guard !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 10) {
                guard bytes.count + newline <= Self.maximumTextRowBytes else { throw FileViewerError.lineTooLong }
                bytes.append(contentsOf: chunk.prefix(newline))
                cursor += Int64(newline + 1)
                break
            }
            guard bytes.count + chunk.count <= Self.maximumTextRowBytes else { throw FileViewerError.lineTooLong }
            bytes.append(contentsOf: chunk)
            cursor += Int64(chunk.count)
        }
        if bytes.last == 13 { bytes.removeLast() }

        let maximum = columns.map { max(1, $0) }
        var display = ""
        display.reserveCapacity(bytes.count)
        var sourceText: String? = includeSourceText ? "" : nil
        if includeSourceText { sourceText?.reserveCapacity(bytes.count) }
        var column = 0
        var consumedBytes = 0
        var parser = Unicode.UTF8.ForwardParser()
        var iterator = bytes.makeIterator()
        var nextCancellationCheck = 0
        decoding: while consumedBytes < bytes.count {
            if consumedBytes >= nextCancellationCheck {
                try Task.checkCancellation()
                nextCancellationCheck = consumedBytes + 4096
            }
            let scalar: Unicode.Scalar
            let byteCount: Int
            switch parser.parseScalar(from: &iterator) {
            case .valid(let encoded): scalar = Unicode.UTF8.decode(encoded); byteCount = encoded.count
            case .error(let length): scalar = "�"; byteCount = length
            case .emptyInput: break decoding
            }

            let rendered: String
            let width: Int
            if scalar == "\t" {
                width = 4 - column % 4
                rendered = String(repeating: " ", count: width)
            } else {
                width = 1
                rendered = CharacterSet.controlCharacters.contains(scalar) ? "·" : String(scalar)
            }
            if let maximum, column + width > maximum, consumedBytes > 0 { break }
            display.append(contentsOf: rendered)
            if includeSourceText { sourceText?.append(contentsOf: String(scalar)) }
            column += width
            consumedBytes += byteCount
        }

        // If wrapping stopped before the logical row boundary, keep
        // the unread bytes for the next visible row instead of advancing to cursor.
        let contentEnd = offset + Int64(consumedBytes)
        let next = consumedBytes < bytes.count ? contentEnd : cursor
        return (display, sourceText, contentEnd, next)
    }

    private func previousLogicalStart(before offset: Int64) async throws -> Int64 {
        guard offset > 0 else { return 0 }
        var cursor = min(offset, size) - 1
        if cursor >= 0, try await byte(at: cursor) == 10 { cursor -= 1 }
        while cursor >= 0 {
            let start = max(0, cursor - 4095)
            let chunk = try await bytes(at: start, count: Int(cursor - start + 1))
            if let newline = chunk.lastIndex(of: 10) { return start + Int64(newline + 1) }
            cursor = start - 1
        }
        return 0
    }

    private func alignedScalarStart(atOrAfter offset: Int64) async throws -> Int64 {
        let first = max(0, offset - 3)
        let sample = try await bytes(at: first, count: 7)
        for start in first..<offset {
            let index = Int(start - first)
            guard index < sample.count else { continue }
            let lead = sample[index]
            let length = lead >= 0xC2 && lead <= 0xDF ? 2
                : lead >= 0xE0 && lead <= 0xEF ? 3
                : lead >= 0xF0 && lead <= 0xF4 ? 4 : 0
            guard length > 0, start + Int64(length) > offset,
                  index + length <= sample.count else { continue }
            let scalar = String(bytes: sample[index..<index + length], encoding: .utf8)
            if scalar?.unicodeScalars.count == 1 { return start + Int64(length) }
        }
        return offset
    }

    private func findWrappedAnchor(before offset: Int64, skipTrailingLF: Bool) async throws
        -> (offset: Int64, isLocalFallback: Bool) {
        var end = max(0, min(offset, size))
        guard end > 0 else { return (0, false) }
        if skipTrailingLF, try await byte(at: end - 1) == 10 { end -= 1 }
        let lower = max(0, end - Self.reverseScanLimit)
        var cursor = end
        while cursor > lower {
            try Task.checkCancellation()
            let start = max(lower, cursor - Int64(Self.readChunkSize))
            let chunk = try await bytes(at: start, count: Int(cursor - start))
            if let newline = chunk.lastIndex(of: 10) { return (start + Int64(newline + 1), false) }
            cursor = start
        }
        if lower == 0 { return (0, false) }
        return (try await alignedScalarStart(atOrAfter: lower), true)
    }

    /// Replays rows from an anchor until one covers the target or ends at/after it.
    private func replay(from anchor: Int64, target: Int64, columns: Int,
                        containing: Bool, navigation: inout ViewerRowNavigation) async throws -> Int64 {
        var cursor = anchor
        var last = anchor
        while cursor < size {
            try Task.checkCancellation()
            let next = try await readRow(at: cursor, columns: columns).next
            guard next > cursor else { break }
            navigation.record(start: cursor, next: next)
            if containing ? (cursor <= target && target < next) : (next >= target) { return cursor }
            last = cursor
            cursor = next
        }
        return last
    }

    private func previousDisplayStart(before offset: Int64, columns: Int?,
                                      navigation: inout ViewerRowNavigation) async throws -> Int64 {
        guard offset > 0 else { return 0 }
        guard let columns else { return try await previousLogicalStart(before: offset) }
        let target = min(offset, size)
        if let cached = navigation.predecessor(endingAt: target) {
            if try await readRow(at: cached, columns: columns).next == target { return cached }
            navigation.removeAll()
        }
        let anchor = try await findWrappedAnchor(before: target, skipTrailingLF: true)
        if anchor.isLocalFallback { navigation.removeAll() }
        return try await replay(from: anchor.offset, target: target, columns: columns,
                                containing: false, navigation: &navigation)
    }

    private func textStart(containing offset: Int64, columns: Int?,
                           navigation: inout ViewerRowNavigation) async throws -> Int64 {
        guard size > 0 else { return 0 }
        let target = max(0, min(offset, size - 1))
        guard let columns else {
            var cursor = target
            while cursor > 0 {
                try Task.checkCancellation()
                let start = max(0, cursor - Int64(Self.readChunkSize))
                let chunk = try await bytes(at: start, count: Int(cursor - start))
                if let newline = chunk.lastIndex(of: 10) { return start + Int64(newline + 1) }
                cursor = start
            }
            return 0
        }
        let anchor = try await findWrappedAnchor(before: target, skipTrailingLF: false)
        if anchor.isLocalFallback { navigation.removeAll() }
        return try await replay(from: anchor.offset, target: target, columns: columns,
                                containing: true, navigation: &navigation)
    }

    private func wrappedEndStart(rows: Int, columns: Int,
                                 navigation: inout ViewerRowNavigation) async throws -> Int64 {
        var position = size
        var remaining = rows
        while remaining > 0 && position > 0 {
            try Task.checkCancellation()
            let start = try await previousDisplayStart(before: position, columns: columns,
                                                       navigation: &navigation)
            guard start < position else { break }
            let next = try await readRow(at: start, columns: columns).next
            if next > position {
                // The fallback replay already replaced incompatible history
                // and retained its prefix. Count the suffix in that alignment,
                // then walk backward through those recorded predecessors.
                var suffix: [Int64] = []
                var cursor = start
                while cursor < size {
                    try Task.checkCancellation()
                    let rowNext = try await readRow(at: cursor, columns: columns).next
                    guard rowNext > cursor else { break }
                    navigation.record(start: cursor, next: rowNext)
                    suffix.append(cursor)
                    if suffix.count > rows { suffix.removeFirst() }
                    cursor = rowNext
                }
                if suffix.count >= rows { return suffix[suffix.count - rows] }
                remaining = rows - suffix.count
            } else {
                remaining -= 1
            }
            position = start
        }
        return position
    }

    public func page(_ command: ViewerCommand = .stay, rows requestedRows: Int,
                     mode requestedMode: ViewerMode = .text, wrapColumns: Int? = nil,
                     includeSourceText: Bool = false) async throws -> ViewerPage {
        await acquirePage()
        let previous = (top, mode, savedTextTop)
        var succeeded = false
        defer {
            if !succeeded { (top, mode, savedTextTop) = previous }
            releasePage()
        }
        try Task.checkCancellation()
        let metadata = try await refreshSize()
        if case .end = command, !sizeKnown {
            size = try await source.length()
            sizeKnown = true
        }
        let count = min(200, max(1, requestedRows))
        let columns = wrapColumns.map { max(1, $0) }
        let context = TextContext(revision: metadata.revision,
                                  fileSize: sizeKnown ? size : nil, columns: columns)
        let contextMatches = lastTextContext?.matches(context) == true
        var navigation = metadata.revision != nil && contextMatches
            ? rowNavigation : ViewerRowNavigation()
        if case .home = command { navigation.removeAll() }
        let enteringText = requestedMode == .text && mode == .hex
        var recoverTextPosition = lastTextContext != nil && !contextMatches
        if requestedMode != mode {
            if requestedMode == .hex {
                savedTextTop = top
                top = (top / 16) * 16
            } else if top == (savedTextTop / 16) * 16 {
                top = savedTextTop
                if !contextMatches || savedTextTop >= size { recoverTextPosition = true }
            } else {
                recoverTextPosition = true
            }
            mode = requestedMode
        }
        if mode == .hex {
            let page = try await hexPage(command, rows: count)
            try Task.checkCancellation()
            if let lastTextContext,
               !lastTextContext.sourceMatches(revision: metadata.revision,
                                              fileSize: sizeKnown ? size : nil) {
                rowNavigation.removeAll()
            }
            succeeded = true
            return page
        }
        if enteringText && !contextMatches { recoverTextPosition = true }
        if top >= size { recoverTextPosition = true }
        if recoverTextPosition {
            switch command {
            case .home, .end: break
            default: top = try await textStart(containing: top, columns: columns, navigation: &navigation)
            }
        }
        switch command {
        case .home: top = 0
        case .end:
            if let columns {
                top = try await wrappedEndStart(rows: count, columns: columns, navigation: &navigation)
            } else {
                top = size
                for _ in 0..<count {
                    top = try await previousDisplayStart(before: top, columns: nil, navigation: &navigation)
                }
            }
        case .scroll(let delta):
            for _ in 0..<abs(max(-200, min(200, delta))) {
                try Task.checkCancellation()
                if delta < 0 {
                    top = try await previousDisplayStart(before: top, columns: columns, navigation: &navigation)
                }
                else {
                    let next = try await readRow(at: top, columns: columns).next
                    if columns != nil { navigation.record(start: top, next: next) }
                    if next > top && next < size { top = next } else { break }
                }
            }
        case .stay: break
        }
        var lines: [ViewerLine] = []
        var cursor = top
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor < size else { break }
            let row = try await readRow(at: cursor, columns: columns, includeSourceText: includeSourceText)
            guard row.next > cursor else { break }
            lines.append(ViewerLine(
                offset: cursor,
                endOffset: row.contentEnd,
                text: row.text,
                sourceText: row.sourceText
            ))
            if columns != nil { navigation.record(start: cursor, next: row.next) }
            cursor = row.next
        }
        try Task.checkCancellation()
        if sizeKnown && metadata.size != nil && size != metadata.size {
            rowNavigation.removeAll()
        } else {
            rowNavigation = columns == nil || metadata.revision == nil ? ViewerRowNavigation() : navigation
            lastTextContext = TextContext(revision: metadata.revision,
                                          fileSize: sizeKnown ? size : nil, columns: columns)
        }
        succeeded = true
        return ViewerPage(lines: lines, offset: top, endOffset: cursor, fileSize: sizeKnown ? size : nil, mode: .text)
    }
    private func hexPage(_ command: ViewerCommand, rows: Int) async throws -> ViewerPage {
        let lastRow = size > 0 ? ((size - 1) / 16) * 16 : 0
        top = min(lastRow, (top / 16) * 16)
        switch command {
        case .home: top = 0
        case .end: top = max(0, lastRow - Int64(rows - 1) * 16)
        case .scroll(let delta):
            let movement = Int64(max(-200, min(200, delta))) * 16
            top = movement > 0 ? top + min(movement, lastRow - top) : max(0, top + movement)
        case .stay: break
        }
        var lines: [ViewerLine] = []
        var cursor = top
        for _ in 0..<rows {
            try Task.checkCancellation()
            guard cursor < size else { break }
            let start = cursor
            let bytes = try await self.bytes(at: cursor, count: 16)
            cursor += Int64(bytes.count)
            guard !bytes.isEmpty else { break }
            lines.append(ViewerLine(
                offset: start,
                endOffset: cursor,
                text: HexRowFormatter.format(offset: start, bytes: bytes),
                sourceText: nil
            ))
        }
        if lines.isEmpty, top > 0, top >= size {
            top = size > 0 ? ((size - 1) / 16) * 16 : 0
            return try await hexPage(.stay, rows: rows)
        }
        return ViewerPage(lines: lines, offset: top, endOffset: cursor, fileSize: sizeKnown ? size : nil, mode: .hex)
    }

}
