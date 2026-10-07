import Foundation
import Darwin

public enum ViewerMode: Sendable { case text, hex }

public enum ViewerCommand: Sendable {
    case stay, scroll(Int), home, end
}

public struct ViewerLine: Sendable {
    public let offset: Int64
    public let text: String
}

public struct ViewerPage: Sendable {
    public let lines: [ViewerLine]
    public let offset: Int64
    public let endOffset: Int64
    public let fileSize: Int64
    public let mode: ViewerMode
}

public enum FileViewerError: LocalizedError {
    case notRegularFile
    case symbolicLinkUnavailable(path: String, target: String, reason: String)
    public var errorDescription: String? {
        switch self {
        case .notRegularFile: "The viewer can only open regular files."
        case let .symbolicLinkUnavailable(path, target, reason):
            "Cannot open symbolic link \(path) → \(target). \(reason)"
        }
    }
}

/// A bounded-memory UTF-8 text reader. No whole-file data or line index is retained.
/// Huge logical lines are divided at stable 4 KiB boundaries (adjusted for UTF-8
/// and CRLF). This makes backward navigation and End bounded too, even without LF.
public actor FileViewerDocument {
    private let descriptor: Int32
    private static let blockSize: Int64 = 4096
    private static let cacheSize = 65_536
    private var cache: [UInt8] = []
    private var cacheStart: Int64 = -1
    private var size: Int64 = 0
    private var top: Int64 = 0
    private var mode: ViewerMode = .text
    private var savedTextTop: Int64 = 0
    private var modified = timespec()
    public private(set) var bytesRead: Int64 = 0

    public init(url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        // open resolves relative, absolute, and chained symlinks atomically in the
        // filesystem; do not normalize their paths before opening.
        guard fd >= 0 else {
            let error = Self.posixError()
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                throw FileViewerError.symbolicLinkUnavailable(path: url.path, target: target,
                    reason: error.localizedDescription)
            }
            throw error
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let error = Self.posixError(); Darwin.close(fd); throw error }
        guard (info.st_mode & S_IFMT) == S_IFREG else { Darwin.close(fd); throw FileViewerError.notRegularFile }
        descriptor = fd
        size = info.st_size
        modified = info.st_mtimespec
    }

    deinit { Darwin.close(descriptor) }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private func refreshSize() throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
        if info.st_size != size || info.st_mtimespec.tv_sec != modified.tv_sec || info.st_mtimespec.tv_nsec != modified.tv_nsec {
            cache = []
            cacheStart = -1
        }
        size = info.st_size
        modified = info.st_mtimespec
        if top >= size {
            top = mode == .hex ? (size > 0 ? ((size - 1) / 16) * 16 : 0) : try previousStart(before: size)
        }
    }

    private func byte(at offset: Int64) throws -> UInt8? {
        guard offset >= 0, offset < size else { return nil }
        if cacheStart < 0 || offset < cacheStart || offset >= cacheStart + Int64(cache.count) {
            let start = (offset / Int64(Self.cacheSize)) * Int64(Self.cacheSize)
            var buffer = [UInt8](repeating: 0, count: Self.cacheSize)
            var count: Int
            repeat {
                count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, off_t(start)) }
            } while count < 0 && errno == EINTR
            guard count >= 0 else { throw Self.posixError() }
            bytesRead += Int64(count)
            cache = Array(buffer.prefix(count))
            cacheStart = start
            // The file may shrink between fstat and pread. An early EOF is safe.
            if count < Self.cacheSize { size = min(size, start + Int64(count)) }
        }
        let index = Int(offset - cacheStart)
        return cache.indices.contains(index) ? cache[index] : nil
    }

    private func boundary(_ base: Int64) throws -> Int64 {
        guard base > 0 else { return 0 }
        var result = min(base, size)
        // Never split a valid UTF-8 scalar or a CRLF pair across artificial rows.
        for _ in 0..<3 {
            guard let value = try byte(at: result), value & 0xC0 == 0x80 else { break }
            result += 1
        }
        // Attach a following LF to this segment, avoiding a spurious empty row.
        if try byte(at: result) == 10 { result += 1 }
        return min(result, size)
    }

    private func nextBoundary(after offset: Int64) throws -> Int64 {
        var base = (offset / Self.blockSize) * Self.blockSize
        var candidate = try boundary(base)
        if candidate <= offset { base += Self.blockSize; candidate = try boundary(base) }
        return candidate
    }

    private func previousStart(before offset: Int64) throws -> Int64 {
        guard offset > 0 else { return 0 }
        let end = min(offset, size)
        var base = ((end - 1) / Self.blockSize) * Self.blockSize
        var start = try boundary(base)
        if start >= end { base = max(0, base - Self.blockSize); start = try boundary(base) }
        var cursor = end - 1
        if try byte(at: cursor) == 10 { cursor -= 1 }
        while cursor >= start {
            if try byte(at: cursor) == 10 { return cursor + 1 }
            cursor -= 1
        }
        return start
    }

    private func readRow(at offset: Int64, columns: Int? = nil) throws -> (text: String, next: Int64) {
        let limit = try nextBoundary(after: offset)
        var cursor = offset
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(Self.blockSize) + 4)
        while cursor < limit, let value = try byte(at: cursor) {
            cursor += 1
            if value == 10 { break }
            bytes.append(value)
        }
        if bytes.last == 13 { bytes.removeLast() }

        let source = String(decoding: bytes, as: UTF8.self)
        let maximum = columns.map { max(1, $0) }
        var display = ""
        var column = 0
        var consumedBytes = 0
        for scalar in source.unicodeScalars {
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
            display += rendered
            column += width
            consumedBytes += String(scalar).utf8.count
        }

        // If wrapping stopped before the artificial/logical row boundary, keep
        // the unread bytes for the next visible row instead of advancing to cursor.
        let next = consumedBytes < bytes.count ? offset + Int64(consumedBytes) : cursor
        return (display, next)
    }

    private func previousDisplayStart(before offset: Int64, columns: Int?) throws -> Int64 {
        guard let columns else { return try previousStart(before: offset) }
        let base = try previousStart(before: offset)
        var cursor = base
        var previous = base
        while cursor < offset {
            let next = try readRow(at: cursor, columns: columns).next
            guard next > cursor else { break }
            if next >= offset { return cursor }
            previous = cursor
            cursor = next
        }
        return previous
    }

    public func page(_ command: ViewerCommand = .stay, rows requestedRows: Int,
                     mode requestedMode: ViewerMode = .text, wrapColumns: Int? = nil) throws -> ViewerPage {
        try Task.checkCancellation()
        try refreshSize()
        let count = min(200, max(1, requestedRows))
        if requestedMode != mode {
            if requestedMode == .hex {
                savedTextTop = top
                top = (top / 16) * 16
            } else if top == (savedTextTop / 16) * 16 && savedTextTop < size {
                top = savedTextTop
            } else {
                top = try previousStart(before: min(top + 1, size))
            }
            mode = requestedMode
        }
        if mode == .hex { return try hexPage(command, rows: count) }
        let columns = wrapColumns.map { max(1, $0) }
        switch command {
        case .home: top = 0
        case .end:
            top = size
            for _ in 0..<count { top = try previousDisplayStart(before: top, columns: columns) }
        case .scroll(let delta):
            for _ in 0..<abs(max(-200, min(200, delta))) {
                try Task.checkCancellation()
                if delta < 0 { top = try previousDisplayStart(before: top, columns: columns) }
                else {
                    let next = try readRow(at: top, columns: columns).next
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
            let row = try readRow(at: cursor, columns: columns)
            guard row.next > cursor else { break }
            lines.append(ViewerLine(offset: cursor, text: row.text))
            cursor = row.next
        }
        return ViewerPage(lines: lines, offset: top, endOffset: cursor, fileSize: size, mode: .text)
    }
    private func hexPage(_ command: ViewerCommand, rows: Int) throws -> ViewerPage {
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
            var bytes: [UInt8] = []
            for _ in 0..<16 {
                guard let value = try byte(at: cursor) else { break }
                bytes.append(value)
                cursor += 1
            }
            guard !bytes.isEmpty else { break }
            lines.append(ViewerLine(offset: start, text: HexRowFormatter.format(offset: start, bytes: bytes)))
        }
        return ViewerPage(lines: lines, offset: top, endOffset: cursor, fileSize: size, mode: .hex)
    }

}
