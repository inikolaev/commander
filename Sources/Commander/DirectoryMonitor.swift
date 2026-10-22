import CoreServices
import Foundation

/// FSEvents includes changes to child contents and metadata, unlike a directory vnode watch.
/// Construct off the UI thread: registering cloud/network paths can block.
final class DirectoryMonitor: @unchecked Sendable {
    // Immutable after initialization; FSEvents owns callback lifetime through its context.
    private let stream: FSEventStreamRef

    private final class Callback: Sendable {
        let onChange: @MainActor @Sendable () -> Void
        init(_ onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
    }

    init?(directory: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        let callback = Callback(onChange)
        defer { withExtendedLifetime(callback) {} }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Callback>.fromOpaque(info).release()
            }, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { callback.onChange() }
        }, &context, [directory.resolvingSymlinksInPath().path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else {
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
