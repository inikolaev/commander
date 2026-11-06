import Foundation
import CFileCopy

public protocol FileCopying: Sendable {
    func copyFile(from source: URL, to destination: URL,
                  progress: @escaping @Sendable (CopyProgress) -> Void,
                  isCancelled: @escaping @Sendable () -> Bool) throws
}

public struct CopyProgress: Sendable {
    public let copiedBytes: Int64
    public let totalBytes: Int64

    public init(copiedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.copiedBytes = copiedBytes
        self.totalBytes = totalBytes
    }
    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(copiedBytes) / Double(totalBytes))) : 0
    }
}

/// Shared between the UI and the worker; the lock protects every access to cancellation.
public final class CopyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

public extension FileCopying {
    func copyFile(from source: URL, to destination: URL) throws {
        try copyFile(from: source, to: destination, progress: { _ in }, isCancelled: { false })
    }
}

/// The C callback is synchronous; this context is retained for the duration of copyfile.
private final class CopyCallbackContext {
    let total: Int64
    let progress: @Sendable (CopyProgress) -> Void
    let isCancelled: @Sendable () -> Bool
    init(total: Int64, progress: @escaping @Sendable (CopyProgress) -> Void,
         isCancelled: @escaping @Sendable () -> Bool) {
        self.total = total
        self.progress = progress
        self.isCancelled = isCancelled
    }
}

public enum FileCopyError: LocalizedError {
    case sameFile, insideSource, unsupportedItem, destinationExists

    public var errorDescription: String? {
        switch self {
        case .sameFile: "The source and destination are the same item. Choose a different name or folder."
        case .insideSource: "A folder cannot be copied inside itself."
        case .unsupportedItem: "This item cannot be copied."
        case .destinationExists: "An item already exists at the destination. Choose a different name; existing items are not overwritten."
        }
    }
}

public struct LocalFileCopier: FileCopying {
    public init() {}

    /// Counts file data without following symlinks. Check cancellation during the
    /// scan as well as during copyfile's callbacks for large directory trees.
    static func byteCount(at source: URL, isCancelled: @Sendable () -> Bool) throws -> Int64 {
        let manager = FileManager.default
        var pending = [source]
        var total: Int64 = 0
        while let item = pending.popLast() {
            if isCancelled() { throw CancellationError() }
            let attributes = try manager.attributesOfItem(atPath: item.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                pending.append(contentsOf: try manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil))
            case .typeRegular:
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let (sum, overflow) = total.addingReportingOverflow(size)
                if overflow { throw CocoaError(.fileReadTooLarge) }
                total = sum
            case .typeSymbolicLink:
                break
            default:
                throw FileCopyError.unsupportedItem
            }
        }
        return total
    }

    private static func restoreDirectoryDates(from source: URL, to destination: URL,
                                              isCancelled: @Sendable () -> Bool) throws {
        let manager = FileManager.default
        var pending: [(source: URL, destination: URL, exiting: Bool)] = [(source, destination, false)]
        while let item = pending.popLast() {
            if isCancelled() { throw CancellationError() }
            if item.exiting {
                let date = try manager.attributesOfItem(atPath: item.source.path)[.modificationDate]
                if let date { try manager.setAttributes([.modificationDate: date], ofItemAtPath: item.destination.path) }
            } else {
                pending.append((item.source, item.destination, true))
                for child in try manager.contentsOfDirectory(at: item.source, includingPropertiesForKeys: nil) {
                    let attributes = try manager.attributesOfItem(atPath: child.path)
                    if attributes[.type] as? FileAttributeType == .typeDirectory {
                        pending.append((child, item.destination.appendingPathComponent(child.lastPathComponent), false))
                    }
                }
            }
        }
    }

    private static func removeStaging(_ stagingDirectory: URL) {
        let manager = FileManager.default
        // A recursive copy can finish with read-only directory permissions.
        // Restore owner access top-down so removeItem can descend on failure.
        var pending = [stagingDirectory]
        while let item = pending.popLast() {
            guard let attributes = try? manager.attributesOfItem(atPath: item.path) else { continue }
            if (attributes[.immutable] as? NSNumber)?.boolValue == true {
                try? manager.setAttributes([.immutable: false], ofItemAtPath: item.path)
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            try? manager.setAttributes([.posixPermissions: mode | 0o700], ofItemAtPath: item.path)
            if let children = try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                pending.append(contentsOf: children)
            }
        }
        try? manager.removeItem(at: stagingDirectory)
    }

    private static func unlockStagedItems(at root: URL) throws -> [String] {
        let manager = FileManager.default
        var pending: [(url: URL, relative: String)] = [(root, "")]
        var locked: [String] = []
        while let item = pending.popLast() {
            let attributes = try manager.attributesOfItem(atPath: item.url.path)
            if (attributes[.immutable] as? NSNumber)?.boolValue == true {
                try manager.setAttributes([.immutable: false], ofItemAtPath: item.url.path)
                locked.append(item.relative)
            }
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                for child in try manager.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil) {
                    let relative = item.relative.isEmpty ? child.lastPathComponent : item.relative + "/" + child.lastPathComponent
                    pending.append((child, relative))
                }
            }
        }
        return locked
    }

    private static func restoreImmutableItems(_ locked: [String], at root: URL) throws {
        let manager = FileManager.default
        for relative in locked.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let item = relative.isEmpty ? root : root.appendingPathComponent(relative)
            try manager.setAttributes([.immutable: true], ofItemAtPath: item.path)
        }
    }

    private static func destinationIsInside(_ source: URL, destination: URL,
                                            sourceAttributes: [FileAttributeKey: Any]) -> Bool {
        let manager = FileManager.default
        guard let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
              let sourceID = sourceAttributes[.systemFileNumber] as? NSNumber else { return false }
        var parent = destination.deletingLastPathComponent().standardizedFileURL
        while true {
            if let attributes = try? manager.attributesOfItem(atPath: parent.path),
               (attributes[.systemNumber] as? NSNumber) == sourceDevice,
               (attributes[.systemFileNumber] as? NSNumber) == sourceID { return true }
            if parent.path == "/" { return false }
            let next = parent.deletingLastPathComponent()
            if next == parent { return false }
            parent = next
        }
    }

    public func copyFile(from source: URL, to destination: URL,
                         progress: @escaping @Sendable (CopyProgress) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        let manager = FileManager.default
        // Resolve parent aliases but preserve the final component, which may be a symlink.
        let from = source.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(source.lastPathComponent).standardizedFileURL
        let to = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        guard from != to else {
            throw FileCopyError.sameFile
        }
        let attributes = try manager.attributesOfItem(atPath: source.path)
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        if isDirectory && (from.path == "/" || to.path.hasPrefix(from.path + "/") ||
                           Self.destinationIsInside(source, destination: to, sourceAttributes: attributes)) {
            throw FileCopyError.insideSource
        }
        // attributesOfItem also sees dangling symlinks, unlike fileExists(atPath:).
        if (try? manager.attributesOfItem(atPath: destination.path)) != nil {
            throw FileCopyError.destinationExists
        }
        // Stage in the destination filesystem so a failed copy never exposes a partial
        // destination. moveItem refuses collisions, including ones created during copying.
        let stagingDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".commander-copy-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { Self.removeStaging(stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent("item")
        let total = try Self.byteCount(at: source, isCancelled: isCancelled)
        progress(CopyProgress(totalBytes: total))
        let context = CopyCallbackContext(total: total, progress: progress, isCancelled: isCancelled)
        let raw = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<CopyCallbackContext>.fromOpaque(raw).release() }
        let error = commander_copy_file(source.path, staged.path, isDirectory ? 1 : 0, { copied, raw in
            guard let raw else { return 1 }
            let context = Unmanaged<CopyCallbackContext>.fromOpaque(raw).takeUnretainedValue()
            if context.isCancelled() { return 1 }
            context.progress(CopyProgress(copiedBytes: copied, totalBytes: context.total))
            return context.isCancelled() ? 1 : 0
        }, raw)
        if isCancelled() { throw CancellationError() }
        if error != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        let locked = try Self.unlockStagedItems(at: staged)
        if isDirectory {
            try Self.restoreDirectoryDates(from: source, to: staged, isCancelled: isCancelled)
        }
        try Self.restoreImmutableItems(locked.filter { !$0.isEmpty }, at: staged)
        if isCancelled() { throw CancellationError() }
        try manager.moveItem(at: staged, to: destination)
        if locked.contains("") {
            try manager.setAttributes([.immutable: true], ofItemAtPath: destination.path)
        }
        progress(CopyProgress(copiedBytes: total, totalBytes: total))
    }
}
