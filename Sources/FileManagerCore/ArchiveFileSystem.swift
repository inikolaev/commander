import Foundation
import ArchiveCore

/// Immutable index. Archive links are metadata only and are never followed.
public struct ArchiveFileSystem: VirtualFileSystem {
    public let archiveURL: URL
    public let root: FileSystemPath
    public var supportsFileOperations: Bool { false }
    private let fingerprint: ArchiveFingerprint?
    private let members: [String: ArchiveEntry]
    private let children: [String: [FileEntry]]

    public static func recognizes(_ url: URL) -> Bool {
        ["zip", "7z", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz", "zst", "tzst", "rar", "cpio", "iso", "cab"].contains(url.pathExtension.lowercased())
    }

    public init(url: URL) throws {
        let snapshot = try Archive.snapshot(at: url)
        try self.init(url: url, entries: snapshot.entries, fingerprint: snapshot.fingerprint)
    }

    public init(url: URL, entries: [ArchiveEntry], fingerprint: ArchiveFingerprint? = nil) throws {
        self.fingerprint = fingerprint
        guard url.isFileURL else { throw ArchiveError("Archive must be a local file") }
        archiveURL = url.standardizedFileURL
        root = FileSystemPath(URL(string: "archive://\(UUID().uuidString.lowercased())/")!)
        var nodes: [String: ArchiveEntry] = [:]
        var explicit: Set<String> = []
        var totalPathBytes = 0
        for entry in entries {
            try Task.checkCancellation()
            let path = try Self.normalize(entry.path)
            guard !path.isEmpty else {
                guard entry.kind == .directory else { throw ArchiveError("Invalid archive root entry") }
                continue
            }
            totalPathBytes += path.utf8.count
            guard totalPathBytes <= 16 * 1024 * 1024 else { throw ArchiveError("Archive path index is too large") }
            let parts = path.split(separator: "/").map(String.init)
            for count in 1..<parts.count {
                let parent = parts.prefix(count).joined(separator: "/")
                if let existing = nodes[parent], existing.kind != .directory {
                    throw ArchiveError("Archive has a file/directory conflict: \(parent)")
                }
                nodes[parent] = nodes[parent] ?? ArchiveEntry(path: parent, kind: .directory)
            }
            if let existing = nodes[path], existing.kind != entry.kind {
                throw ArchiveError("Archive has conflicting entries: \(path)")
            }
            // Duplicate directories are common; ambiguous duplicate files are rejected.
            guard !explicit.contains(path) || entry.kind == .directory else { throw ArchiveError("Archive has duplicate entries: \(path)") }
            explicit.insert(path)
            nodes[path] = entry
            guard nodes.count <= 200_000 else { throw ArchiveError("Archive directory index is too large") }
        }
        members = nodes
        var index: [String: [FileEntry]] = ["": []]
        for (path, entry) in nodes {
            let parts = path.split(separator: "/")
            let parent = parts.dropLast().joined(separator: "/")
            let name = String(parts.last!)
            let address = root.url.appendingPathComponent(path)
            index[parent, default: []].append(FileEntry(url: address, name: name,
                isDirectory: entry.kind == .directory, isSymbolicLink: entry.kind == .symbolicLink,
                size: entry.kind == .directory ? nil : entry.size, modified: entry.modified))
            if entry.kind == .directory { index[path, default: []] += [] }
        }
        children = index.mapValues { entries in
            entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
            }
        }
    }

    /// Reject host-absolute, traversal, Windows, and control-character paths before indexing.
    public static func normalize(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveError("Unsafe archive pathname")
        }
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !parts.contains(".."), parts.count <= 128, path.utf8.count <= 4096,
              !(parts.first?.contains(":") ?? false) else { throw ArchiveError("Unsafe or excessive archive pathname") }
        return parts.joined(separator: "/")
    }

    public func snapshot(at path: FileSystemPath, showHidden: Bool) throws -> DirectorySnapshot {
        guard path.url.scheme == root.url.scheme, path.url.host == root.url.host,
              let entries = children[String(path.url.path.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/"))] else {
            throw ArchiveError("Archive directory does not exist")
        }
        return DirectorySnapshot(entries: showHidden ? entries : entries.filter { !$0.isHidden })
    }

    private func member(at path: FileSystemPath) -> ArchiveEntry? {
        guard path.url.scheme == root.url.scheme, path.url.host == root.url.host else { return nil }
        return members[String(path.url.path.dropFirst())]
    }

    public func canViewFile(at path: FileSystemPath) -> Bool {
        fingerprint != nil && member(at: path)?.kind == .file
    }

    public func openFile(at path: FileSystemPath) async throws -> any FileContentSource {
        guard let fingerprint, let entry = member(at: path), entry.kind == .file else {
            throw ArchiveError("Only regular archive files can be viewed")
        }
        return try ArchiveFileContentSource(url: archiveURL, fingerprint: fingerprint, entry: entry)
    }

    public var session: FileSystemSession {
        FileSystemSession(fileSystem: self, path: root, hostDirectory: archiveURL.deletingLastPathComponent(), exitSelection: archiveURL)
    }
}
