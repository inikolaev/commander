import EditorCore
import Foundation
import SyntaxCore

/// Owns the parser lifetime and serial updates for one editor.
@MainActor
final class EditorSyntaxController {
    nonisolated static let maximumFileSize = 512 * 1024
    private let document: any EditorDocument
    private let url: URL
    private let onProjection: (EditorSyntaxProjection) -> Void
    private var observerID: UUID?
    private var flushTask: Task<Void, Never>?
    private var initialTask: Task<Void, Never>?
    private var initialBuildTask: Task<(SyntaxEditingSession, EditorSyntaxProjection)?, Never>?
    private var updateTask: Task<Void, Never>?
    private var updateBuildTask: Task<EditorSyntaxProjection, Never>?
    private var session: SyntaxEditingSession?
    private var pending: [SyntaxEditingDelta] = []
    private var unprojected: [EditorContentDelta] = []
    private var latestVersion: Int
    private var generation = 0
    private var closed = false
    private(set) var projection = EditorSyntaxProjection.empty
    var hasEditingSession: Bool { session != nil }
    var hasPendingSyntaxWork: Bool {
        flushTask != nil || initialTask != nil || initialBuildTask != nil ||
            updateTask != nil || updateBuildTask != nil || !pending.isEmpty
    }

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
        let generation = self.generation
        let url = self.url
        // The actor initializer parses synchronously, so construct it on a
        // detached executor rather than on the main actor.
        let build = Task.detached(priority: .utility) {
            if Task.isCancelled { return nil as (SyntaxEditingSession, EditorSyntaxProjection)? }
            let session = SyntaxRegistry.viewer.editingSession(
                for: url, data: Data(initialText.utf8), maximumFileSize: Self.maximumFileSize)
            let highlighter = await session.highlighter()
            if Task.isCancelled { return nil }
            let projected = EditorSyntaxProjection.make(source: initialText, highlighter: highlighter)
            return (session, projected)
        }
        initialBuildTask = build
        initialTask = Task { [weak self] in
            let built = await build.value
            guard let self, !self.closed, self.generation == generation else { return }
            self.initialTask = nil
            self.initialBuildTask = nil
            guard let built else { return }
            self.session = built.0
            if self.document.contentVersion == version { self.publish(built.1) }
            if !self.pending.isEmpty { self.schedule() }
        }
    }

    private func record(_ change: EditorContentChange) {
        guard !closed, change.version > latestVersion else { return }
        guard SyntaxRegistry.viewer.supports(url) else { return }
        // The document can already contain a nested edit whose notification is
        // still queued. A recovery snapshot must use that newer version.
        let currentVersion = document.contentVersion
        guard currentDocumentIsWithinLimit() else {
            invalidateWork()
            latestVersion = currentVersion
            publish(.empty)
            return
        }
        if session == nil && initialTask == nil {
            let source = document.text(in: NSRange(location: 0, length: document.length))
            latestVersion = currentVersion
            unprojected.removeAll()
            publish(.empty)
            startInitial(source: source)
            return
        }
        latestVersion = change.version
        unprojected.append(contentsOf: change.changes)
        // A preceding observer may have made a nested edit. Its notification
        // follows this one, so only publish after all deltas reach the current
        // document version.
        if currentVersion == change.version {
            var provisional = projection.applying(unprojected)
            if unprojected.contains(where: { $0.range.length != 0 ||
                !$0.insertedText.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
            }) {
                let source = document.text(in: NSRange(location: 0, length: document.length))
                provisional = provisional.clippingToGraphemes(in: source)
            }
            unprojected.removeAll(keepingCapacity: true)
            publish(provisional)
        }
        pending.append(contentsOf: change.changes.map { SyntaxEditingDelta(range: $0.range, insertedText: $0.insertedText) })
        // Coalesce edits in this main-actor turn. While a parser update is in
        // flight, subsequent edits form the next batch.
        schedule()
    }

    private func currentDocumentIsWithinLimit() -> Bool {
        guard document.length <= Self.maximumFileSize else { return false }
        // A UTF-16 code unit expands to at most three UTF-8 bytes. Small
        // documents need no whole-document read on the normal edit path.
        if document.length <= Self.maximumFileSize / 3 { return true }
        return currentSourceWithinLimit() != nil
    }

    private func currentSourceWithinLimit() -> String? {
        guard document.length <= Self.maximumFileSize else { return nil }
        let source = document.text(in: NSRange(location: 0, length: document.length))
        return source.utf8.count <= Self.maximumFileSize ? source : nil
    }

    private func invalidateWork() {
        generation += 1
        flushTask?.cancel()
        flushTask = nil
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
        unprojected.removeAll()
    }

    private func schedule() {
        guard session != nil, updateTask == nil, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard !closed, let session, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let version = latestVersion
        let generation = self.generation
        // Only materialize a source snapshot when projection is possible.
        let source = currentSourceWithinLimit()
        let build = Task.detached(priority: .utility) { () -> EditorSyntaxProjection in
            let highlighter = (try? await session.apply(batch)) ?? PlainTextSyntaxHighlighter.shared
            guard !Task.isCancelled, let source, source.utf8.count <= Self.maximumFileSize else { return .empty }
            return EditorSyntaxProjection.make(source: source, highlighter: highlighter)
        }
        updateBuildTask = build
        updateTask = Task { [weak self] in
            let projected = await build.value
            guard let self, !self.closed, self.generation == generation else { return }
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
        if let observerID { document.removeContentChangeObserver(observerID) }
        observerID = nil
        invalidateWork()
        projection = .empty
    }
}
