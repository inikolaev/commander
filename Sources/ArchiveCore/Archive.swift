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

/// Metadata-only reader. C pointers never escape their owning call; no extraction or external filters.
public enum Archive {
    public static func entries(at url: URL, maximumEntries: Int = 100_000) throws -> [ArchiveEntry] {
        guard url.isFileURL else { throw ArchiveError("Archive must be a local file") }
        // Open once, without blocking on a FIFO, and validate that same descriptor.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw ArchiveError(String(cString: strerror(errno))) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveError("Archive must be a regular local file")
        }
        // libarchive converts UTF-8 headers through the calling thread's locale.
        // Scope this to the synchronous reader; never mutate the process locale.
        guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else {
            throw ArchiveError("Cannot create UTF-8 filename locale")
        }
        let previousLocale = uselocale(locale)
        defer { uselocale(previousLocale); freelocale(locale) }
        guard let reader = archive_read_new() else { throw ArchiveError("Cannot allocate archive reader") }
        defer { archive_read_free(reader) }
        func check(_ status: Int32) throws {
            guard status == ARCHIVE_OK else {
                throw ArchiveError(archive_error_string(reader).map { String(cString: $0) } ?? "Archive read failed (\(status))")
            }
        }
        // Never use support_filter_all: unsupported filters may spawn host tools.
        for status in [archive_read_support_filter_none(reader), archive_read_support_filter_gzip(reader),
                       archive_read_support_filter_bzip2(reader), archive_read_support_filter_xz(reader),
                       archive_read_support_filter_lzma(reader), archive_read_support_filter_zstd(reader),
                       archive_read_support_format_all(reader)] { try check(status) }
        try check(archive_read_open_fd(reader, descriptor, 64 * 1024))
        var result: [ArchiveEntry] = []
        var pathBytes = 0
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            try check(status)
            guard result.count < maximumEntries else { throw ArchiveError("Archive exceeds the \(maximumEntries) entry limit") }
            guard let entry, let name = archive_entry_pathname_utf8(entry),
                  let path = String(validatingCString: name) else { throw ArchiveError("Archive contains a filename that cannot be decoded as UTF-8") }
            pathBytes += path.utf8.count
            guard path.utf8.count <= 4096, pathBytes <= 16 * 1024 * 1024 else {
                throw ArchiveError("Archive filename metadata exceeds the size limit")
            }
            guard archive_entry_is_encrypted(entry) == 0 else { throw ArchiveError("Encrypted archives are not supported") }
            let kind: ArchiveEntry.Kind
            if archive_entry_hardlink(entry) != nil { kind = .hardLink }
            else {
                switch archive_entry_filetype(entry) {
                case 0o040000: kind = .directory
                case 0o100000: kind = .file
                case 0o120000: kind = .symbolicLink
                default: kind = .other
                }
            }
            result.append(ArchiveEntry(path: path, kind: kind,
                size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
                modified: archive_entry_mtime_is_set(entry) != 0 ? Date(timeIntervalSince1970: Double(archive_entry_mtime(entry))) : nil,
                permissions: UInt16(archive_entry_perm(entry))))
            try check(archive_read_data_skip(reader))
        }
        guard archive_read_has_encrypted_entries(reader) <= 0 else { throw ArchiveError("Encrypted archives are not supported") }
        try check(archive_read_close(reader))
        return result
    }
}
