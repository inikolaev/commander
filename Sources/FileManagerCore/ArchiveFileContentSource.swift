import Foundation
import Darwin
import ArchiveCore

/// Progressive materialization. All state and C reads are serialized on this
/// background actor, without yielding between consuming and retaining bytes.
public actor ArchiveFileContentSource: FileContentSource {
    private let stream: ArchiveEntryStream
    private let declaredSize: Int64?
    private let memoryLimit: Int
    private let expandedLimit: Int64
    private var memory = Data()
    private var spill: Int32 = -1
    private var failure: (any Error)?
    public private(set) var materializedBytes: Int64 = 0
    public var usesDisk: Bool { spill >= 0 }

    public init(url: URL, fingerprint: ArchiveFingerprint, entry: ArchiveEntry,
                memoryLimit: Int = 4 * 1024 * 1024, expandedLimit: Int64 = 1024 * 1024 * 1024) throws {
        guard memoryLimit >= 0, expandedLimit >= 0 else { throw ContentSourceError.invalidRange }
        self.memoryLimit = memoryLimit; self.expandedLimit = expandedLimit
        declaredSize = entry.size
        stream = try ArchiveEntryStream(url: url, fingerprint: fingerprint, entry: entry)
    }
    deinit { if spill >= 0 { Darwin.close(spill) } }

    public func metadata() throws -> ContentMetadata {
        try Task.checkCancellation()
        if let failure { throw failure }
        do {
            try stream.validate()
            if declaredSize == 0, !stream.isAtEnd { try prepare(through: 0) }
            return ContentMetadata(size: stream.isAtEnd ? materializedBytes : declaredSize)
        } catch {
            recordFailure(error)
            throw error
        }
    }

    public func length() throws -> Int64 {
        try prepare(through: nil)
        return materializedBytes
    }

    public func read(at offset: Int64, count: Int) throws -> Data {
        try validateContentRange(offset: offset, count: count)
        _ = try metadata()
        guard count > 0 else { return Data() }
        try prepare(through: offset + Int64(count))
        let available = Int(min(Int64(count), max(0, materializedBytes - offset)))
        guard available > 0 else { return Data() }
        if spill < 0 { return memory.subdata(in: Int(offset)..<Int(offset) + available) }
        var result = Data(count: available)
        var total = 0
        while total < available {
            try Task.checkCancellation()
            let count = result.withUnsafeMutableBytes {
                pread(spill, $0.baseAddress!.advanced(by: total), available - total, off_t(offset + Int64(total)))
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                let error = posixError(); recordFailure(error); throw error
            }
            total += count
        }
        return result
    }

    private func prepare(through end: Int64?) throws {
        if let failure { throw failure }
        do {
            try stream.validate()
            while !stream.isAtEnd && (end == nil || materializedBytes < end! || materializedBytes == declaredSize) {
                try Task.checkCancellation()
                // One-byte probe at the limit distinguishes exact EOF from excess.
                let remaining = max(0, expandedLimit - materializedBytes)
                let amount = remaining >= 65_536 ? 65_536 : Int(remaining) + 1
                let bytes = try stream.read(maximumCount: amount)
                guard Int64(bytes.count) <= remaining else { throw ArchiveError("Viewing exceeds the expanded-file limit (\(expandedLimit) bytes)") }
                if !bytes.isEmpty {
                    try append(bytes)
                    materializedBytes += Int64(bytes.count)
                }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError() // Successfully retained chunks remain reusable.
        } catch {
            recordFailure(error)
            throw error
        }
    }

    private func recordFailure(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        failure = error
        memory = Data()
        if spill >= 0 { Darwin.close(spill); spill = -1 }
    }

    private func append(_ data: Data) throws {
        if spill < 0, materializedBytes + Int64(data.count) > Int64(memoryLimit) {
            var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("commander-view-XXXXXX").path.utf8CString)
            let descriptor = mkstemp(&template)
            guard descriptor >= 0 else { throw posixError() }
            // Unlinked files cannot escape via member names and disappear on close/crash.
            guard unlink(template) == 0 else { let error = posixError(); Darwin.close(descriptor); throw error }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) >= 0 else {
                let error = posixError(); Darwin.close(descriptor); throw error
            }
            spill = descriptor
            try write(memory)
            memory = Data()
        }
        if spill >= 0 { try write(data) }
        else { memory.append(data) }
    }
    private func write(_ data: Data) throws {
        var total = 0
        while total < data.count {
            let count = data.withUnsafeBytes { Darwin.write(spill, $0.baseAddress!.advanced(by: total), $0.count - total) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw posixError() }
            total += count
        }
    }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
