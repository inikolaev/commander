import AppKit
import FileManagerCore

/// Runs native moves sequentially, reporting completed moves even after an error.
@MainActor
final class MoveCoordinator {
    struct Outcome {
        let completed: [FileMove]
        let succeeded: Bool
    }
    private let mover: any FileMoving
    private let presenter = OperationDialogPresenter()
    private(set) var isBusy = false

    init(mover: any FileMoving = LocalFileMover()) { self.mover = mover }

    func begin(sources: [URL], directory: URL, window: NSWindow,
               onFinish: @escaping (Outcome) -> Void) {
        guard let first = sources.first, !isBusy, window.attachedSheet == nil else { return }
        isBusy = true
        let value = sources.count == 1 ? directory.appendingPathComponent(first.lastPathComponent).path : directory.path
        let prompt = sources.count == 1 ? "Move \(first.lastPathComponent) to:" : "Move \(sources.count) selected items to folder:"
        let dialog = TerminalOperationDialog(mode: .textInput(title: "Move", prompt: prompt,
            value: value, confirmTitle: "Move"))
        dialog.onCancel = { [weak self] in self?.finish(window: window) }
        dialog.onConfirm = { [weak self] input in
            guard let self else { return }
            let path = (input as NSString).expandingTildeInPath
            guard !path.isEmpty else {
                self.showError("Enter a destination path.", window: window) { onFinish(Outcome(completed: [], succeeded: false)) }
                return
            }
            let destination = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)).standardizedFileURL
            let mover = self.mover
            self.presenter.present(TerminalOperationDialog(mode: .busy(title: "Move", message: "Preparing move…")), window: window)
            Task {
                var completed: [FileMove] = []
                do {
                    let plan = try await Task.detached(priority: .userInitiated) {
                        try FileMovePlan.make(sources: sources, destination: destination)
                    }.value
                    for item in plan {
                        let progress = TerminalOperationDialog(mode: .busy(title: "Move",
                            message: "Moving \(completed.count + 1) of \(plan.count)\n\n\(item.source.lastPathComponent)\nTo: \(item.destination.path)"))
                        self.presenter.present(progress, window: window)
                        try await Task.detached(priority: .userInitiated) {
                            try mover.moveItem(from: item.source, to: item.destination)
                        }.value
                        completed.append(item)
                    }
                    self.finish(window: window)
                    onFinish(Outcome(completed: completed, succeeded: true))
                } catch {
                    let outcome = Outcome(completed: completed, succeeded: false)
                    let message = "\(error.localizedDescription)\n\n\(completed.count) items moved before stopping. Completed moves are kept."
                    self.showError(message, window: window) { onFinish(outcome) }
                }
            }
        }
        presenter.present(dialog, window: window)
    }

    private func showError(_ message: String, window: NSWindow, onDismiss: @escaping () -> Void) {
        let dialog = TerminalOperationDialog(mode: .error(message: message, title: "Move error"))
        dialog.onDismiss = { [weak self] in self?.finish(window: window); onDismiss() }
        presenter.present(dialog, window: window)
    }

    private func finish(window: NSWindow) {
        presenter.dismiss(window: window)
        isBusy = false
    }
}
