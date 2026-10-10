import Foundation

/// File I/O is independent of both the buffer implementation and its renderer.
/// Ordinary text files are held in memory; the existing viewer remains unbounded.
public struct EditorFile: Sendable {
    public let url: URL
    public let text: String
    // Initial line index is prepared alongside normalization, in UTF-16 offsets.
    let preparedLineStarts: [Int]?
    public private(set) var isNew = false
    private let original: Data
    private let newline: String
    private let hasBOM: Bool

    public static func open(_ url: URL) throws -> EditorFile {
        let trace = EditorLoadTrace()
        let resolved = url.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw Failure("Only regular text files can be edited.") }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        trace.checkpoint("resolve-and-open")
        let data = try handle.readToEnd() ?? Data()
        trace.checkpoint("read-bytes")
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let payload = bom ? data.dropFirst(3) : data[...]
        let prepared = try EditorTextPreparation.prepareFile(payload)
        trace.checkpoint("prepare-text")
        return EditorFile(url: resolved, text: prepared.text, preparedLineStarts: prepared.lineStarts,
            original: data, newline: prepared.newline, hasBOM: bom)
    }

    /// Opens an existing name, or prepares an unsaved file without touching disk.
    public static func openOrNew(name: String, in directory: URL) throws -> EditorFile {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw Failure("Enter a file name, without slashes. The names . and .. are not allowed.")
        }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            var file = EditorFile(url: url, text: "", preparedLineStarts: [0],
                original: Data(), newline: "\n", hasBOM: false)
            file.isNew = true
            return file
        }
        return try open(url)
    }

    /// Saves to a sibling temporary file, then replaces the original. Symlinks
    /// remain links. Reject external modifications instead of silently losing them.
    public func save(text: String) throws -> EditorFile {
        let text = EditorDocuments.normalizeNewlines(text)
        var data = Data()
        if hasBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(contentsOf: text.replacingOccurrences(of: "\n", with: newline).utf8)
        if isNew {
            // Exclusive creation also rejects a file or symlink added since the prompt.
            try data.write(to: url, options: .withoutOverwriting)
            return EditorFile(url: url, text: text, preparedLineStarts: nil,
                original: data, newline: newline, hasBOM: hasBOM)
        }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 <= 1 else {
            throw Failure("Saving files with multiple hard links is not supported yet.")
        }
        guard try currentContentsMatch() else {
            throw Failure("The file has changed on disk. Your edits are still open; saving was cancelled.")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".commander-edit-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        // Copy first to retain permissions and extended attributes.
        try manager.copyItem(at: url, to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        guard try currentContentsMatch() else {
            throw Failure("The file changed while saving. Your edits are still open.")
        }
        _ = try manager.replaceItemAt(url, withItemAt: temporary)
        return EditorFile(url: url, text: text, preparedLineStarts: nil, original: data, newline: newline, hasBOM: hasBOM)
    }

    private func currentContentsMatch() throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Compare incrementally: checking a large file should not allocate
        // another file-sized buffer, even if the file grew externally.
        var offset = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= original.count - offset,
                  chunk == original[offset..<(offset + chunk.count)] else { return false }
            offset += chunk.count
        }
        return offset == original.count
    }

    public struct Failure: LocalizedError, Sendable {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
}
