import Foundation

/// A filesystem address. Non-file URLs are identifiers, never host filesystem paths.
public struct FileSystemPath: Hashable, Sendable {
    public let url: URL
    public init(_ url: URL) { self.url = url.isFileURL ? url.standardizedFileURL : url.standardized }
    public var localURL: URL? { url.isFileURL ? url : nil }
    public var parent: FileSystemPath? {
        // Foundation versions differ on whether deleting a virtual root's last
        // component returns "/" or an empty path. Both represent the root.
        guard !url.path.isEmpty, url.path != "/" else { return nil }
        let parent = FileSystemPath(url.deletingLastPathComponent())
        return parent.url.path == url.path ? nil : parent
    }
}

public struct DirectorySnapshot: Sendable {
    public let entries: [FileEntry]
    public let modified: Date?
    public init(entries: [FileEntry], modified: Date? = nil) {
        self.entries = entries
        self.modified = modified
    }
}

public protocol VirtualFileSystem: Sendable {
    var supportsFileOperations: Bool { get }
    func snapshot(at path: FileSystemPath, showHidden: Bool) throws -> DirectorySnapshot
    func canViewFile(at path: FileSystemPath) -> Bool
    func openFile(at path: FileSystemPath) async throws -> any FileContentSource
}

public extension VirtualFileSystem {
    func canViewFile(at path: FileSystemPath) -> Bool { false }
    func openFile(at path: FileSystemPath) async throws -> any FileContentSource {
        throw CocoaError(.fileReadUnsupportedScheme)
    }
}

public struct LocalFileSystem: VirtualFileSystem {
    private let reader: any DirectoryReading
    public var supportsFileOperations: Bool { true }
    public func canViewFile(at path: FileSystemPath) -> Bool { path.localURL != nil }
    public func openFile(at path: FileSystemPath) async throws -> any FileContentSource {
        guard let url = path.localURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try LocalFileContentSource(url: url)
    }
    public init(reader: any DirectoryReading = LocalDirectoryReader()) { self.reader = reader }
    public func snapshot(at path: FileSystemPath, showHidden: Bool) throws -> DirectorySnapshot {
        guard let url = path.localURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return DirectorySnapshot(entries: try reader.entries(at: url, showHidden: showHidden),
            modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }
}

/// Value navigation context; immutable filesystem snapshots can be shared by panes.
public struct FileSystemSession: Sendable {
    public let fileSystem: any VirtualFileSystem
    public let path: FileSystemPath
    public let hostDirectory: URL
    public let exitSelection: URL?
    public init(fileSystem: any VirtualFileSystem, path: FileSystemPath,
                hostDirectory: URL? = nil, exitSelection: URL? = nil) {
        self.fileSystem = fileSystem
        self.path = path
        self.hostDirectory = hostDirectory ?? path.localURL ?? FileManager.default.homeDirectoryForCurrentUser
        self.exitSelection = exitSelection
    }
    public func navigating(to url: URL) -> Self {
        Self(fileSystem: fileSystem, path: FileSystemPath(url),
            hostDirectory: url.isFileURL ? url : hostDirectory, exitSelection: exitSelection)
    }
    public var displayPath: String {
        if let exitSelection { return exitSelection.path + "!" + path.url.path }
        return path.url.path
    }
}

extension URL {
    var selectionAddress: URL { FileSystemPath(self).url }
}
