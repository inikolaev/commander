import Foundation
import Darwin

public struct ContentMetadata: Sendable {
    /// Nil means unknown, never the length of a partially prepared cache.
    public let size: Int64?
    public init(size: Int64?) { self.size = size }
}

/// Stateful, random-access bytes. Implementations own caching and resource lifetimes.
/// Reads must execute off the main actor, and return fewer bytes only at EOF.
/// Cancellation is checked between bounded I/O operations. No byte is an implicit hole.
public protocol FileContentSource: Sendable {
    func metadata() async throws -> ContentMetadata
    func read(at offset: Int64, count: Int) async throws -> Data
    /// Resolve an unknown size; sequential sources may need to finish reading.
    func length() async throws -> Int64
}

public enum ContentSourceError: Error, LocalizedError {
    case invalidRange
    public var errorDescription: String? { "Invalid file byte range." }
}

func validateContentRange(offset: Int64, count: Int) throws {
    guard offset >= 0, count >= 0, !offset.addingReportingOverflow(Int64(count)).overflow else {
        throw ContentSourceError.invalidRange
    }
}

/// Actor isolation keeps blocking local I/O off the UI executor. The descriptor
/// stays open for this source's lifetime, including across pathname renames.
public actor LocalFileContentSource: FileContentSource {
    private let descriptor: Int32
    private let bufferSize: Int
    private var buffer = Data()
    private var bufferOffset: Int64 = -1
    private var size: Int64 = 0
    private var modified = timespec()
    public private(set) var bytesRead: Int64 = 0

    public init(url: URL, bufferSize: Int = 65_536) throws {
        guard url.isFileURL, bufferSize > 0 else { throw ContentSourceError.invalidRange }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            let error = Self.posixError()
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                throw FileViewerError.symbolicLinkUnavailable(path: url.path, target: target, reason: error.localizedDescription)
            }
            throw error
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { let error = Self.posixError(); Darwin.close(fd); throw error }
        guard info.st_mode & S_IFMT == S_IFREG else { Darwin.close(fd); throw FileViewerError.notRegularFile }
        descriptor = fd
        self.bufferSize = bufferSize
        size = info.st_size
        modified = info.st_mtimespec
    }

    deinit { Darwin.close(descriptor) }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    public func metadata() throws -> ContentMetadata {
        try Task.checkCancellation()
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError() }
        if info.st_size != size || info.st_mtimespec.tv_sec != modified.tv_sec || info.st_mtimespec.tv_nsec != modified.tv_nsec {
            buffer = Data(); bufferOffset = -1
        }
        size = info.st_size; modified = info.st_mtimespec
        return ContentMetadata(size: size)
    }

    public func length() throws -> Int64 { try metadata().size! }

    public func read(at offset: Int64, count: Int) throws -> Data {
        try validateContentRange(offset: offset, count: count)
        _ = try metadata()
        var result = Data()
        var cursor = offset
        while result.count < count, cursor < size {
            try Task.checkCancellation()
            if cursor < bufferOffset || cursor >= bufferOffset + Int64(buffer.count) {
                let start = cursor / Int64(bufferSize) * Int64(bufferSize)
                var bytes = [UInt8](repeating: 0, count: bufferSize)
                var received = 0
                while received < bufferSize {
                    try Task.checkCancellation()
                    let amount = bytes.withUnsafeMutableBytes {
                        pread(descriptor, $0.baseAddress!.advanced(by: received), bufferSize - received, off_t(start + Int64(received)))
                    }
                    if amount < 0, errno == EINTR { continue }
                    guard amount >= 0 else { throw Self.posixError() }
                    if amount == 0 { break }
                    received += amount
                    bytesRead += Int64(amount)
                }
                buffer = Data(bytes.prefix(received))
                bufferOffset = start
                if received < bufferSize { size = min(size, start + Int64(received)) }
                if cursor >= size { break }
            }
            let start = Int(cursor - bufferOffset)
            let amount = min(count - result.count, buffer.count - start)
            result.append(buffer[start..<start + amount])
            cursor += Int64(amount)
        }
        return result
    }
}
