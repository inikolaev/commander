import Foundation

/// Copies in listing order, stopping at the first failure. Each individual copy
/// retains FileCopying's staging, cancellation, and no-overwrite guarantees.
public struct FileCopyBatch: Sendable {
    public let sources: [URL]
    public let destination: URL

    public init(sources: [URL], destination: URL) {
        self.sources = sources
        self.destination = destination
    }

    public func run(using copier: any FileCopying,
                    progress: @escaping @Sendable (CopyProgress) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) throws -> URL {
        guard !sources.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        if sources.count == 1 {
            try copier.copyFile(from: sources[0], to: destination, progress: progress, isCancelled: isCancelled)
            return destination
        }
        if sources.count > 1 {
            guard try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        let sizes = try sources.map { try LocalFileCopier.byteCount(at: $0, isCancelled: isCancelled) }
        let total = try sizes.reduce(Int64(0)) { count, size in
            let (sum, overflow) = count.addingReportingOverflow(size)
            if overflow { throw CocoaError(.fileReadTooLarge) }
            return sum
        }
        var completed: Int64 = 0
        var lastDestination = destination
        for (index, source) in sources.enumerated() {
            if isCancelled() { throw CancellationError() }
            let target = sources.count == 1 ? destination : destination.appendingPathComponent(source.lastPathComponent)
            let baseline = completed
            do {
                try copier.copyFile(from: source, to: target, progress: { value in
                    progress(CopyProgress(copiedBytes: baseline + value.copiedBytes, totalBytes: total))
                }, isCancelled: isCancelled)
            } catch is CancellationError { throw CancellationError() }
            catch {
                throw BatchCopyFailure(source: source, completedCount: index, underlying: error)
            }
            completed += sizes[index]
            progress(CopyProgress(copiedBytes: completed, totalBytes: total))
            lastDestination = target
        }
        return lastDestination
    }
}

private struct BatchCopyFailure: LocalizedError {
    let source: URL
    let completedCount: Int
    let underlying: Error
    var errorDescription: String? {
        "Could not copy \(source.lastPathComponent). \(underlying.localizedDescription)\n\n\(completedCount) items copied before stopping. Completed copies are kept."
    }
}
