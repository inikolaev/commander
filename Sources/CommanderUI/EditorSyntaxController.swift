import EditorCore
import Foundation
import SyntaxCore

/// Owns the parser lifetime and serial, debounced updates for one editor.
@MainActor
final class EditorSyntaxController {
    nonisolated static let maximumFileSize = 512 * 1024
    private let document: any EditorDocument
    private let url: URL
    private let onProjection: (EditorSyntaxProjection) -> Void
    private var observerID: UUID?
    private var timer: Timer?
    private var initialTask: Task<Void, Never>?
    private var initialBuildTask: Task<(SyntaxEditingSession, EditorSyntaxProjection), Never>?
    private var updateTask: Task<Void, Never>?
    private var updateBuildTask: Task<EditorSyntaxProjection, Never>?
    private var session: SyntaxEditingSession?
    private var pending: [SyntaxEditingDelta] = []
    private var latestVersion: Int
    private var closed = false
    private(set) var projection = EditorSyntaxProjection.empty

    init(document: any EditorDocument, url: URL, initialText: String,
         onProjection: @escaping (EditorSyntaxProjection) -> Void) {
        self.document = document
        self.url = url
        self.onProjection = onProjection
        latestVersion = document.contentVersion
        observerID = document.addContentChangeObserver { [weak self] change in
            MainActor.assumeIsolated { self?.record(change) }
        }
        guard SyntaxRegistry.viewer.supports(url), initialText.utf8.count <= Self.maximumFileSize else { return }
        startInitial(source: initialText)
    }

    private func startInitial(source initialText: String) {
        let version = latestVersion
        let url = self.url
        // The actor initializer parses synchronously, so construct it on a
        // detached executor rather than on the main actor.
        let build = Task.detached(priority: .utility) {
            let session = SyntaxRegistry.viewer.editingSession(
                for: url, data: Data(initialText.utf8), maximumFileSize: Self.maximumFileSize)
            let highlighter = await session.highlighter()
            let projected = EditorSyntaxProjection.make(source: initialText, highlighter: highlighter)
            return (session, projected)
        }
        initialBuildTask = build
        initialTask = Task { [weak self] in
            let built = await build.value
            guard let self, !self.closed else { return }
            self.initialTask = nil
            self.initialBuildTask = nil
            self.session = built.0
            if self.document.contentVersion == version { self.publish(built.1) }
            if !self.pending.isEmpty { self.schedule() }
        }
    }

    private func record(_ change: EditorContentChange) {
        guard !closed else { return }
        latestVersion = change.version
        publish(.empty)
        if session == nil && initialTask == nil {
            guard SyntaxRegistry.viewer.supports(url), document.length <= Self.maximumFileSize else { return }
            let source = document.text(in: NSRange(location: 0, length: document.length))
            guard source.utf8.count <= Self.maximumFileSize else { return }
            startInitial(source: source)
            return
        }
        pending.append(contentsOf: change.changes.map { SyntaxEditingDelta(range: $0.range, insertedText: $0.insertedText) })
        // One timer and at most one parser update are active. Repeated edits
        // move the deadline without creating worker jobs for each keystroke.
        schedule()
    }

    private func schedule() {
        guard session != nil, updateTask == nil else { return }
        if let timer { timer.fireDate = Date().addingTimeInterval(0.1) }
        else { timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        } }
    }

    private func flush() {
        timer = nil
        guard !closed, let session, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let version = latestVersion
        // Only materialize a source snapshot when projection is possible.
        let source: String? = document.length <= Self.maximumFileSize
            ? document.text(in: NSRange(location: 0, length: document.length)) : nil
        let build = Task.detached(priority: .utility) { () -> EditorSyntaxProjection in
            let highlighter = (try? await session.apply(batch)) ?? PlainTextSyntaxHighlighter.shared
            guard !Task.isCancelled, let source, source.utf8.count <= Self.maximumFileSize else { return .empty }
            return EditorSyntaxProjection.make(source: source, highlighter: highlighter)
        }
        updateBuildTask = build
        updateTask = Task { [weak self] in
            let projected = await build.value
            guard let self, !self.closed else { return }
            self.updateTask = nil
            self.updateBuildTask = nil
            if self.document.contentVersion == version { self.publish(projected) }
            if !self.pending.isEmpty { self.schedule() }
        }
    }

    private func publish(_ next: EditorSyntaxProjection) {
        projection = next
        onProjection(next)
    }

    func close() {
        closed = true
        timer?.invalidate()
        timer = nil
        if let observerID { document.removeContentChangeObserver(observerID) }
        observerID = nil
        initialTask?.cancel()
        initialBuildTask?.cancel()
        updateTask?.cancel()
        updateBuildTask?.cancel()
        initialTask = nil
        initialBuildTask = nil
        updateTask = nil
        updateBuildTask = nil
        session = nil
        pending.removeAll()
        projection = .empty
    }
}
