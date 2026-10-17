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
/// Wrapped mode advances in bounded chunks, while unwrapped mode preserves actual
/// newline-delimited logical lines so disabling wrap never invents visible rows.
public actor FileViewerDocument {
    private let source: any FileContentSource
    private static let blockSize: Int64 = 4096
    private var size: Int64 = 0
    private var sizeKnown = true
    private var top: Int64 = 0
    private var mode: ViewerMode = .text
    private var savedTextTop: Int64 = 0
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

    private func refreshSize() async throws {
        let metadata = try await source.metadata()
        sizeKnown = metadata.size != nil
        size = metadata.size ?? Int64.max
        if top >= size {
            top = mode == .hex ? (size > 0 ? ((size - 1) / 16) * 16 : 0) : try await previousStart(before: size)
        }
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

    private func boundary(_ base: Int64) async throws -> Int64 {
        guard base > 0 else { return 0 }
        var result = min(base, size)
        // Never split a valid UTF-8 scalar or a CRLF pair across artificial rows.
        for _ in 0..<3 {
            guard let value = try await byte(at: result), value & 0xC0 == 0x80 else { break }
            result += 1
        }
        // Attach a following LF to this segment, avoiding a spurious empty row.
        if try await byte(at: result) == 10 { result += 1 }
        return min(result, size)
    }

    private func nextBoundary(after offset: Int64) async throws -> Int64 {
        var base = (offset / Self.blockSize) * Self.blockSize
        var candidate = try await boundary(base)
        if candidate <= offset { base += Self.blockSize; candidate = try await boundary(base) }
        return candidate
    }

    private func previousStart(before offset: Int64) async throws -> Int64 {
        guard offset > 0 else { return 0 }
        let end = min(offset, size)
        var base = ((end - 1) / Self.blockSize) * Self.blockSize
        var start = try await boundary(base)
        if start >= end { base = max(0, base - Self.blockSize); start = try await boundary(base) }
        var cursor = end - 1
        if try await byte(at: cursor) == 10 { cursor -= 1 }
        if cursor >= start {
            let chunk = try await bytes(at: start, count: Int(cursor - start + 1))
            if let newline = chunk.lastIndex(of: 10) { return start + Int64(newline + 1) }
        }
        return start
    }

    private func readRow(at offset: Int64, columns: Int? = nil, includeSourceText: Bool = false) async throws
        -> (text: String, sourceText: String?, contentEnd: Int64, next: Int64) {
        // Wrapped rows never need to read beyond the next bounded chunk because
        // the visible terminal width is far smaller than blockSize. Unwrapped
        // rows, however, must continue until the real newline/EOF.
        let limit = columns == nil ? size : try await nextBoundary(after: offset)
        var cursor = offset
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(Self.blockSize) + 4)
        while cursor < limit {
            let chunk = try await self.bytes(at: cursor, count: Int(min(4096, limit - cursor)))
            guard !chunk.isEmpty else { break }
            if let newline = chunk.firstIndex(of: 10) {
                guard bytes.count + newline <= 16 * 1024 * 1024 else { throw FileViewerError.lineTooLong }
                bytes.append(contentsOf: chunk.prefix(newline))
                cursor += Int64(newline + 1)
                break
            }
            guard bytes.count + chunk.count <= 16 * 1024 * 1024 else { throw FileViewerError.lineTooLong }
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

        // If wrapping stopped before the artificial/logical row boundary, keep
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

    private func previousDisplayStart(before offset: Int64, columns: Int?) async throws -> Int64 {
        guard let columns else { return try await previousLogicalStart(before: offset) }
        let base = try await previousStart(before: offset)
        var cursor = base
        var previous = base
        while cursor < offset {
            let next = try await readRow(at: cursor, columns: columns).next
            guard next > cursor else { break }
            if next >= offset { return cursor }
            previous = cursor
            cursor = next
        }
        return previous
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
        try await refreshSize()
        if case .end = command, !sizeKnown {
            size = try await source.length()
            sizeKnown = true
        }
        let count = min(200, max(1, requestedRows))
        if requestedMode != mode {
            if requestedMode == .hex {
                savedTextTop = top
                top = (top / 16) * 16
            } else if top == (savedTextTop / 16) * 16 && savedTextTop < size {
                top = savedTextTop
            } else {
                top = try await previousStart(before: min(top + 1, size))
            }
            mode = requestedMode
        }
        if mode == .hex {
            let page = try await hexPage(command, rows: count)
            try Task.checkCancellation()
            succeeded = true
            return page
        }
        let columns = wrapColumns.map { max(1, $0) }
        switch command {
        case .home: top = 0
        case .end:
            top = size
            for _ in 0..<count { top = try await previousDisplayStart(before: top, columns: columns) }
        case .scroll(let delta):
            for _ in 0..<abs(max(-200, min(200, delta))) {
                try Task.checkCancellation()
                if delta < 0 { top = try await previousDisplayStart(before: top, columns: columns) }
                else {
                    let next = try await readRow(at: top, columns: columns).next
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
            cursor = row.next
        }
        try Task.checkCancellation()
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
