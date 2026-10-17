import Foundation
import Darwin
import CLibArchive

/// Identity of the descriptor used for indexing, not a later pathname lookup.
public struct ArchiveFingerprint: Sendable, Equatable {
    private let device: Int32
    private let inode: UInt64
    private let size: Int64
    private let modifiedSeconds: Int
    private let modifiedNanos: Int
    private let changedSeconds: Int
    private let changedNanos: Int

    init(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveError("Archive must be a regular local file")
        }
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
}

/// A synchronous, single-owner C handle. Never share it across concurrent calls.
/// Callers run it on a background actor or worker. Locale scope never crosses await.
final class ArchiveReadHandle {
    let fingerprint: ArchiveFingerprint
    private let descriptor: Int32
    private let reader: OpaquePointer
    private let locale: locale_t

    init(url: URL, expected: ArchiveFingerprint? = nil) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ArchiveError("Archive must be a local file") }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { throw ArchiveError(String(cString: strerror(errno))) }
        var owned = false
        defer { if !owned { Darwin.close(fd) } }
        let fingerprint = try ArchiveFingerprint(descriptor: fd)
        guard expected == nil || expected == fingerprint else { throw ArchiveError("Archive changed; leave and reopen it before viewing files") }
        guard let reader = archive_read_new() else { throw ArchiveError("Cannot allocate archive reader") }
        defer { if !owned { archive_read_free(reader) } }
        guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else { throw ArchiveError("Cannot create UTF-8 filename locale") }
        defer { if !owned { freelocale(locale) } }
        let previous = uselocale(locale)
        defer { uselocale(previous) }
        // Do not enable external filter programs.
        for status in [archive_read_support_filter_none(reader), archive_read_support_filter_gzip(reader),
                       archive_read_support_filter_bzip2(reader), archive_read_support_filter_xz(reader),
                       archive_read_support_filter_lzma(reader), archive_read_support_filter_zstd(reader),
                       archive_read_support_format_all(reader)] { try Self.check(status, reader: reader) }
        try Self.check(archive_read_open_fd(reader, fd, 65_536), reader: reader)
        self.descriptor = fd; self.reader = reader; self.locale = locale; self.fingerprint = fingerprint
        owned = true
    }

    deinit { archive_read_free(reader); freelocale(locale); Darwin.close(descriptor) }

    private static func check(_ status: Int32, reader: OpaquePointer) throws {
        guard status == ARCHIVE_OK else {
            throw ArchiveError(archive_error_string(reader).map { String(cString: $0) } ?? "Archive read failed (\(status))")
        }
    }
    private func withLocale<T>(_ body: () throws -> T) rethrows -> T {
        let previous = uselocale(locale)
        defer { uselocale(previous) }
        return try body()
    }
    func validate() throws {
        guard try ArchiveFingerprint(descriptor: descriptor) == fingerprint else { throw ArchiveError("Archive changed while reading") }
    }
    func next() throws -> ArchiveEntry? {
        try Task.checkCancellation()
        return try withLocale {
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { return nil }
            try Self.check(status, reader: reader)
            guard let entry, let name = archive_entry_pathname_utf8(entry), let path = String(validatingCString: name) else {
                throw ArchiveError("Archive contains a filename that cannot be decoded as UTF-8")
            }
            guard path.utf8.count <= 4096 else { throw ArchiveError("Archive filename metadata exceeds the size limit") }
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
            let size = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil
            guard size == nil || size! >= 0 else { throw ArchiveError("Invalid archive member size") }
            return ArchiveEntry(path: path, kind: kind, size: size,
                modified: archive_entry_mtime_is_set(entry) != 0 ? Date(timeIntervalSince1970: Double(archive_entry_mtime(entry))) : nil,
                permissions: UInt16(archive_entry_perm(entry)))
        }
    }
    func skip() throws {
        try Task.checkCancellation()
        try withLocale { try Self.check(archive_read_data_skip(reader), reader: reader) }
    }
    func advanceToNextMember() throws {
        let format = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK
        if archive_filter_code(reader, 0) == ARCHIVE_FILTER_NONE,
           format == ARCHIVE_FORMAT_ZIP || format == ARCHIVE_FORMAT_TAR {
            try skip()
        } else {
            while !(try read(maximumCount: 65_536)).isEmpty {}
        }
    }

    func read(maximumCount: Int) throws -> Data {
        try Task.checkCancellation()
        return try withLocale {
            var data = Data(count: maximumCount)
            let count = data.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
            guard count >= 0 else {
                throw ArchiveError(archive_error_string(reader).map { String(cString: $0) } ?? "Cannot read archive member")
            }
            data.count = count
            return data
        }
    }
}

/// A single member's forward stream. It deliberately has no Sendable conformance:
/// create and use it inside one source actor. No archive paths become output paths.
public final class ArchiveEntryStream {
    private let handle: ArchiveReadHandle
    private let entry: ArchiveEntry
    public private(set) var bytesRead: Int64 = 0
    public private(set) var isAtEnd = false

    public init(url: URL, fingerprint: ArchiveFingerprint, entry: ArchiveEntry) throws {
        guard entry.kind == .file else { throw ArchiveError("Only regular archive files can be viewed") }
        let handle = try ArchiveReadHandle(url: url, expected: fingerprint)
        var found = false
        while let candidate = try handle.next() {
            if candidate.path == entry.path {
                guard candidate == entry else { throw ArchiveError("Archive member changed; reopen the archive") }
                found = true
                break
            }
            // Seekable formats can skip unrelated payloads. Sequential formats
            // drain chunks so cancellation can interrupt locating a late member.
            try handle.advanceToNextMember()
        }
        guard found else { throw ArchiveError("Archive member is no longer available") }
        try handle.validate()
        self.handle = handle; self.entry = entry
    }

    public func validate() throws { try handle.validate() }

    public func read(maximumCount: Int = 65_536) throws -> Data {
        guard maximumCount > 0, maximumCount <= 65_536 else { throw ArchiveError("Invalid archive read size") }
        try handle.validate()
        if isAtEnd { return Data() }
        let data = try handle.read(maximumCount: maximumCount)
        try handle.validate()
        let next = bytesRead + Int64(data.count)
        guard entry.size == nil || next <= entry.size! else { throw ArchiveError("Archive member exceeds its declared size") }
        if data.isEmpty {
            guard entry.size == nil || next == entry.size else { throw ArchiveError("Archive member ended before its declared size") }
            isAtEnd = true
        }
        bytesRead = next
        return data
    }
}
