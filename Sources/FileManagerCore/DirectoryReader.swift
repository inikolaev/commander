import Darwin
import Foundation

/// Snapshot identity, stable across renames on the same filesystem. Hard links share it.
public struct FileIdentity: Sendable, Hashable {
    public let device: Int32
    public let inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    static func read(at url: URL) -> FileIdentity? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
}

public struct FileEntry: Sendable, Equatable {
    // Cache normalization while the entry exists; Foundation may normalize a vanished path differently.
    let selectionURL: URL
    public let identity: FileIdentity?
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64?
    public let modified: Date?
    public let isExecutable: Bool
    public let cloudStatus: CloudFileStatus
    public let isHidden: Bool

    public init(url: URL, name: String, isDirectory: Bool, isSymbolicLink: Bool,
                size: Int64?, modified: Date?, isExecutable: Bool = false, isHidden: Bool = false,
                cloudStatus: CloudFileStatus = .none, identity: FileIdentity? = nil) {
        self.selectionURL = url.standardizedFileURL
        self.identity = identity
        self.cloudStatus = cloudStatus
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
        self.isExecutable = isExecutable
        self.isHidden = isHidden || name.hasPrefix(".")
    }
}

/// Filesystem access is replaceable without coupling navigation to a UI framework.
public protocol DirectoryReading: Sendable {
    func entries(at directory: URL, showHidden: Bool) throws -> [FileEntry]
}

public struct LocalDirectoryReader: DirectoryReading {
    public init() {}

    public func entries(at directory: URL, showHidden: Bool) throws -> [FileEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
            .isUbiquitousItemKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return urls.map { url in
            // An individual unreadable or vanished entry must not break the entire listing.
            let values = try? url.resourceValues(forKeys: keys)
            let isLink = values?.isSymbolicLink == true
            var isDirectory = values?.isDirectory ?? false
            if isLink {
                // Query the target through the filesystem. URL path normalization can
                // retain aliases such as /tmp, whose resource values describe the link.
                var targetIsDirectory: ObjCBool = false
                isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &targetIsDirectory)
                    && targetIsDirectory.boolValue
            }
            return FileEntry(
                url: url, name: url.lastPathComponent,
                isDirectory: isDirectory,
                isSymbolicLink: isLink,
                size: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                isExecutable: !isDirectory && FileManager.default.isExecutableFile(atPath: url.path),
                isHidden: values?.isHidden == true,
                cloudStatus: .resolve(isUbiquitous: values?.isUbiquitousItem,
                    isDownloading: values?.ubiquitousItemIsDownloading, status: values?.ubiquitousItemDownloadingStatus),
                identity: FileIdentity.read(at: url)
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.name < rhs.name : order == .orderedAscending
        }
    }
}
