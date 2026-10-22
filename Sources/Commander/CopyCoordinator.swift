import AppKit
import FileManagerCore

/// The worker writes snapshots; the UI samples them without queueing a task per chunk.
private final class CopyProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CopyProgress()
    func publish(_ progress: CopyProgress) { lock.withLock { value = progress } }
    func read() -> CopyProgress { lock.withLock { value } }
}

/// Owns the modal lifecycle, leaving actual copying to FileCopying.
@MainActor
final class CopyCoordinator {
    private let copier: any FileCopying
    private(set) var isBusy = false
    private let presenter = OperationDialogPresenter()
    private var cancellation: CopyCancellation?

    init(copier: any FileCopying = LocalFileCopier()) { self.copier = copier }

    func begin(source: URL, directory: URL, window: NSWindow,
               onStart: @escaping () -> Void,
               onFinish: @escaping (Result<URL, Error>) -> Void) {
        begin(sources: [source], directory: directory, window: window, onStart: onStart, onFinish: onFinish)
    }

    func begin(sources: [URL], directory: URL, window: NSWindow,
               onStart: @escaping () -> Void,
               onFinish: @escaping (Result<URL, Error>) -> Void) {
        guard let source = sources.first, !isBusy, window.attachedSheet == nil else { return }
        isBusy = true
        let dialog = TerminalOperationDialog(mode: .confirmation(sourceName: sources.count == 1 ? source.lastPathComponent : "\(sources.count) selected files",
            destination: sources.count == 1 ? directory.appendingPathComponent(source.lastPathComponent).path : directory.path,
            isBatch: sources.count > 1))
        dialog.onCancel = { [weak self] in self?.finish(window: window) }
        dialog.onConfirm = { [weak self] input in
            guard let self else { return }
            let path = (input as NSString).expandingTildeInPath
            guard !path.isEmpty else {
                self.showError("Enter a destination file path.", window: window) {
                    onFinish(.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError)))
                }
                return
            }
            let destination = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
            self.copy(sources: sources, destination: destination, window: window, onStart: onStart, onFinish: onFinish)
        }
        present(dialog, window: window)
    }

    private func copy(sources: [URL], destination: URL, window: NSWindow,
                      onStart: @escaping () -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
        let dialog = TerminalOperationDialog(mode: .progress(sourceName: sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) selected files", destination: destination.path))
        let token = CopyCancellation()
        cancellation = token
        dialog.onCancel = { [weak dialog] in token.cancel(); dialog?.showCancelling() }
        present(dialog, window: window)
        onStart()
        let copier = self.copier
        let mailbox = CopyProgressMailbox()
        Task { [self] in
            let poller = Task { @MainActor [weak dialog] in
                while !Task.isCancelled {
                    dialog?.update(progress: mailbox.read())
                    do { try await Task.sleep(for: .milliseconds(60)) } catch { break }
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try FileCopyBatch(sources: sources, destination: destination).run(using: copier,
                        progress: { mailbox.publish($0) }, isCancelled: { token.isCancelled })
                }
            }.value
            poller.cancel()
            cancellation = nil
            switch result {
            case .success:
                finish(window: window)
                onFinish(result)
            case .failure(let error) where error is CancellationError:
                finish(window: window)
                onFinish(result)
            case .failure(let error):
                showError(error.localizedDescription, window: window) { onFinish(result) }
            }
        }
    }

    private func showError(_ message: String, window: NSWindow, onDismiss: @escaping () -> Void) {
        let dialog = TerminalOperationDialog(mode: .error(message: message))
        dialog.toolTip = message
        dialog.onDismiss = { [weak self] in self?.finish(window: window); onDismiss() }
        present(dialog, window: window)
    }

    private func present(_ dialog: TerminalOperationDialog, window: NSWindow) {
        presenter.present(dialog, window: window)
    }

    private func finish(window: NSWindow) {
        presenter.dismiss(window: window)
        isBusy = false
    }
}
