import Foundation
import Darwin
import CLibArchive

public struct ArchiveEntry: Sendable, Equatable {
    public enum Kind: Sendable { case file, directory, symbolicLink, hardLink, other }
    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let modified: Date?
    public let permissions: UInt16
    public init(path: String, kind: Kind, size: Int64? = nil, modified: Date? = nil, permissions: UInt16 = 0) {
        self.path = path; self.kind = kind; self.size = size; self.modified = modified; self.permissions = permissions
    }
}

public struct ArchiveError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ArchiveSnapshot: Sendable {
    public let entries: [ArchiveEntry]
    public let fingerprint: ArchiveFingerprint
}

public enum Archive {
    public static func entries(at url: URL, maximumEntries: Int = 100_000) throws -> [ArchiveEntry] {
        try snapshot(at: url, maximumEntries: maximumEntries).entries
    }

    public static func snapshot(at url: URL, maximumEntries: Int = 100_000) throws -> ArchiveSnapshot {
        let handle = try ArchiveReadHandle(url: url)
        var entries: [ArchiveEntry] = []
        var pathBytes = 0
        while let entry = try handle.next() {
            guard entries.count < maximumEntries else { throw ArchiveError("Archive exceeds the \(maximumEntries) entry limit") }
            pathBytes += entry.path.utf8.count
            guard pathBytes <= 16 * 1024 * 1024 else { throw ArchiveError("Archive filename metadata exceeds the size limit") }
            entries.append(entry)
            try handle.skip()
        }
        try handle.validate()
        return ArchiveSnapshot(entries: entries, fingerprint: handle.fingerprint)
    }
}
