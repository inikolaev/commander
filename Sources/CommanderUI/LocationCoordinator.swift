import AppKit
import FileManagerCore

@MainActor
final class LocationCoordinator {
    private let reader: any LocationReading
    private let presenter = OperationDialogPresenter()
    private(set) var isPresented = false
    private var task: Task<Void, Never>?

    init(reader: any LocationReading = LocalLocationReader()) { self.reader = reader }

    isolated deinit { task?.cancel() }

    func begin(paneName: String, window: NSWindow, onSelect: @escaping (URL) -> Void) {
        guard !isPresented, window.attachedSheet == nil else { return }
        isPresented = true
        let loading = TerminalOperationDialog(mode: .list(title: "Locations — \(paneName)", message: "Finding locations…", items: []))
        loading.onCancel = { [weak self] in self?.finish(window) }
        presenter.present(loading, window: window)
        let reader = self.reader
        task = Task { [weak self] in
            let locations = await Task.detached(priority: .userInitiated) { reader.locations() }.value
            guard !Task.isCancelled, let self, self.isPresented else { return }
            self.task = nil
            let dialog = TerminalOperationDialog(mode: .list(title: "Locations — \(paneName)",
                message: "Choose a location", items: locations.map { "\($0.name) — \($0.url.path)" }))
            dialog.onCancel = { [weak self] in self?.finish(window) }
            dialog.onChoice = { [weak self] index in
                guard let self, self.isPresented, locations.indices.contains(index) else { return }
                self.finish(window)
                onSelect(locations[index].url)
            }
            self.presenter.present(dialog, window: window)
        }
    }

    private func finish(_ window: NSWindow) {
        task?.cancel()
        task = nil
        presenter.dismiss(window: window)
        isPresented = false
    }
}
