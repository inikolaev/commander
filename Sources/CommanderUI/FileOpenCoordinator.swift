import AppKit

@MainActor
protocol FileOpening {
    func defaultApplication(for file: URL) -> URL?
    func applications(for file: URL) -> [URL]
    func open(_ file: URL, with application: URL) async throws
}

@MainActor
struct WorkspaceFileOpener: FileOpening {
    func defaultApplication(for file: URL) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: file) }
    func applications(for file: URL) -> [URL] { NSWorkspace.shared.urlsForApplications(toOpen: file) }
    func open(_ file: URL, with application: URL) async throws {
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration())
    }
}

@MainActor
final class FileOpenCoordinator {
    private let opener: any FileOpening
    private let presenter = OperationDialogPresenter()
    private(set) var isBusy = false

    init(opener: any FileOpening = WorkspaceFileOpener()) { self.opener = opener }

    func begin(file: URL, window: NSWindow) {
        guard !isBusy, window.attachedSheet == nil else { return }
        isBusy = true
        do {
            // A missing file must not be mistaken for a missing handler.
            _ = try file.resourceValues(forKeys: [.isRegularFileKey])
            if let app = opener.defaultApplication(for: file) { launch(file, app: app, window: window) }
            else { choose(file, window: window) }
        } catch { showError(error, window: window) { self.finish(window) } }
    }

    private func choose(_ file: URL, window: NSWindow) {
        let apps = opener.applications(for: file)
        let dialog = TerminalOperationDialog(mode: .list(title: "Open with", message: "No default app: \(file.lastPathComponent)",
            items: apps.map { "\($0.deletingPathExtension().lastPathComponent) — \($0.path)" } + ["Other…"]))
        dialog.onCancel = { self.finish(window) }
        dialog.onChoice = { index in
            if apps.indices.contains(index) { self.launch(file, app: apps[index], window: window) }
            else { self.browse(file, directory: URL(fileURLWithPath: "/Applications"), window: window) }
        }
        presenter.present(dialog, window: window)
    }

    private func browse(_ file: URL, directory: URL, window: NSWindow) {
        presenter.present(TerminalOperationDialog(mode: .busy(title: "Choose application", message: "Loading \(directory.path)…")), window: window)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey], options: [.skipsHiddenFiles])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
            }.value
            switch result {
            case .failure(let error):
                self.showError(error, window: window) { self.enterPath(file, directory: directory, window: window) }
            case .success(let entries):
                let dialog = TerminalOperationDialog(mode: .list(title: "Choose application", message: directory.path,
                    items: ["Enter path…", ".."] + entries.map { $0.lastPathComponent }))
                dialog.onCancel = { self.choose(file, window: window) }
                dialog.onChoice = { index in
                    if index == 0 { self.enterPath(file, directory: directory, window: window) }
                    else if index == 1 { self.browse(file, directory: directory.deletingLastPathComponent(), window: window) }
                    else if entries.indices.contains(index - 2) { self.select(file, url: entries[index - 2], window: window) }
                }
                self.presenter.present(dialog, window: window)
            }
        }
    }

    private func enterPath(_ file: URL, directory: URL, window: NSWindow) {
        let dialog = TerminalOperationDialog(mode: .textInput(title: "Choose application", prompt: "Application or folder path:",
            value: directory.path, confirmTitle: "Choose"))
        dialog.onCancel = { self.browse(file, directory: directory, window: window) }
        dialog.onConfirm = { path in
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
            self.select(file, url: url.standardizedFileURL, window: window)
        }
        presenter.present(dialog, window: window)
    }

    private func select(_ file: URL, url: URL, window: NSWindow) {
        do {
            let values = try url.resourceValues(forKeys: [.isApplicationKey, .isDirectoryKey])
            if values.isApplication == true { launch(file, app: url, window: window) }
            else if values.isDirectory == true { browse(file, directory: url, window: window) }
            else { throw NSError(domain: "Commander", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an application bundle (.app) or a folder."]) }
        } catch {
            showError(error, window: window) { self.enterPath(file, directory: url.deletingLastPathComponent(), window: window) }
        }
    }

    private func launch(_ file: URL, app: URL, window: NSWindow) {
        presenter.present(TerminalOperationDialog(mode: .busy(title: "Open file", message: "Opening \(file.lastPathComponent)…")), window: window)
        Task {
            do { try await opener.open(file, with: app); finish(window) }
            catch { showError(error, window: window) { self.finish(window) } }
        }
    }

    private func showError(_ error: Error, window: NSWindow, onDismiss: @escaping () -> Void) {
        let dialog = TerminalOperationDialog(mode: .error(message: error.localizedDescription, title: "Open file error"))
        dialog.onDismiss = onDismiss
        presenter.present(dialog, window: window)
    }

    private func finish(_ window: NSWindow) {
        presenter.dismiss(window: window)
        isBusy = false
    }
}
