import Foundation

enum DocumentSearchDirection: Sendable { case forward, backward }

enum DocumentSearchScanResult<Hit: Sendable>: Sendable {
    case found(Hit)
    case exhausted
    case cancelled
    case sourceChanged
}

/// The view owns the content origin. The controller owns one search session,
/// continuation, wraparound, and all work started by that session.
@MainActor
final class DocumentSearchController<Offset: FixedWidthInteger & Sendable, Hit: Sendable, Revision: Equatable & Sendable> {
    struct Stamp: Equatable, Sendable {
        let session: UUID
        let generation: UInt64
        let revision: Revision
    }

    enum Status: Equatable {
        case idle
        case searching(Double?) // nil means indeterminate
        case found(wrapped: Bool)
        case noMatches
        case sourceChanged
        case error(String)

        var displayText: String {
            switch self {
            case .idle: ""
            case .searching(let fraction):
                if let fraction { "Searching… \(Int((fraction * 100).rounded()))%" }
                else { "Searching…" }
            case .found(let wrapped): wrapped ? "Wrapped" : ""
            case .noMatches: "No matches"
            case .sourceChanged: "File changed; search again"
            case .error(let message): message
            }
        }
    }

    /// The optional limit applies to match starts, not match ends. Forward
    /// scans accept starts in [anchor, limit); backward scans accept starts
    /// in (limit, anchor]. Adapters must stop at the limit even on no-hit
    /// files, so wrapping never rescans the first interval.
    typealias Scan = @Sendable (
        _ query: DocumentSearchQuery,
        _ direction: DocumentSearchDirection,
        _ anchor: Offset,
        _ exclusiveLimit: Offset?,
        _ progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> DocumentSearchScanResult<Hit>

    var onStatus: ((Status) -> Void)?
    var onHit: ((Hit, Bool) -> Void)?
    private(set) var query = DocumentSearchQuery()
    private(set) var status: Status = .idle {
        didSet {
            switch status {
            case .noMatches, .sourceChanged, .error: activeHit = nil
            case .idle, .searching, .found: break
            }
            onStatus?(status)
        }
    }
    private(set) var isOpen = false
    private(set) var activeHit: Hit?
    private(set) var stamp: Stamp
    private var origin: Offset
    private var task: Task<Void, Never>?
    private var lastProgressTime: TimeInterval = 0
    private let revision: @MainActor () -> Revision
    private let hitStart: @Sendable (Hit) -> Offset
    private let wrapStart: @Sendable (DocumentSearchDirection) async throws -> Offset?
    private let scan: Scan
    private let validate: @Sendable (Hit, DocumentSearchQuery) async throws -> Bool

    init(
        origin: Offset,
        revision: @escaping @MainActor () -> Revision,
        hitStart: @escaping @Sendable (Hit) -> Offset,
        wrapStart: @escaping @Sendable (DocumentSearchDirection) async throws -> Offset?,
        scan: @escaping Scan,
        validate: @escaping @Sendable (Hit, DocumentSearchQuery) async throws -> Bool = { _, _ in true }
    ) {
        self.origin = origin
        self.revision = revision
        self.hitStart = hitStart
        self.wrapStart = wrapStart
        self.scan = scan
        self.validate = validate
        stamp = Stamp(session: UUID(), generation: 0, revision: revision())
    }

    func open(at origin: Offset) {
        if !isOpen {
            isOpen = true
            stamp = Stamp(session: UUID(), generation: stamp.generation &+ 1, revision: revision())
        }
        invalidate()
        self.origin = origin
        activeHit = nil
        if !query.text.isEmpty { start(.forward, continuing: false) }
        else { status = .idle }
    }

    func setQuery(_ query: DocumentSearchQuery) {
        guard self.query != query else { return }
        self.query = query
        activeHit = nil
        invalidate()
        guard isOpen, !query.text.isEmpty else { status = .idle; return }
        start(.forward, continuing: false)
    }

    func continueSearch(_ direction: DocumentSearchDirection) {
        guard isOpen, !query.text.isEmpty else { return }
        start(direction, continuing: activeHit != nil)
    }

    /// Call when the user moves the caret or viewer independently of search.
    func manualNavigation(to origin: Offset) {
        self.origin = origin
        activeHit = nil
        invalidate()
        status = .idle
    }

    /// Call on editor mutation, viewer source change, or undo/redo.
    func documentDidChange(origin: Offset) { manualNavigation(to: origin) }

    /// A page can catch up to a hit found against newer source metadata.
    /// Keep that validated hit while rebasing the request stamp used by
    /// continuation and late-callback fencing.
    func displayedRevisionDidCatchUp() {
        task?.cancel()
        task = nil
        stamp = Stamp(session: stamp.session, generation: stamp.generation &+ 1, revision: revision())
    }

    func dismiss() {
        isOpen = false
        activeHit = nil
        invalidate()
        status = .idle
    }

    func close() {
        dismiss()
        onHit = nil
        onStatus = nil
    }

    private func invalidate() {
        task?.cancel()
        task = nil
        stamp = Stamp(session: stamp.session, generation: stamp.generation &+ 1, revision: revision())
    }

    private func current(_ request: Stamp) -> Bool {
        isOpen && stamp == request && revision() == request.revision
    }

    private func start(_ direction: DocumentSearchDirection, continuing: Bool) {
        invalidate()
        let request = stamp
        let query = self.query
        let anchor = continuing ? hitStart(activeHit!) : origin
        let firstAnchor: Offset?
        if continuing {
            switch direction {
            case .forward: firstAnchor = anchor == Offset.max ? nil : anchor + 1
            case .backward: firstAnchor = anchor == 0 ? nil : anchor - 1
            }
        } else { firstAnchor = anchor }
        status = .searching(nil)
        lastProgressTime = 0
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let progress: @Sendable (Double?) -> Void = { [weak self] fraction in
                    Task { @MainActor [weak self] in self?.reportProgress(fraction, request: request) }
                }
                if let firstAnchor {
                    let first = try await scan(query, direction, firstAnchor, nil, progress)
                    guard current(request) else { return }
                    switch first {
                    case .found(let hit):
                        await accept(hit, wrapped: false, request: request, query: query)
                        return
                    case .cancelled: return
                    case .sourceChanged: status = .sourceChanged; return
                    case .exhausted: break
                    }
                }
                let wrapAnchor = try await wrapStart(direction)
                guard current(request) else { return }
                guard let wrappedAnchor = wrapAnchor else { status = .noMatches; return }
                if firstAnchor == wrappedAnchor { status = .noMatches; return }
                let wrapped = try await scan(query, direction, wrappedAnchor, firstAnchor, progress)
                guard current(request) else { return }
                switch wrapped {
                case .found(let hit):
                    if let firstAnchor {
                        let start = hitStart(hit)
                        let inWrappedInterval = direction == .forward
                            ? start < firstAnchor : start > firstAnchor
                        guard inWrappedInterval else { status = .sourceChanged; return }
                    }
                    await accept(hit, wrapped: true, request: request, query: query)
                case .exhausted: status = .noMatches
                case .sourceChanged: status = .sourceChanged
                case .cancelled: break
                }
            } catch is CancellationError {
                // A newer generation owns the visible status.
            } catch {
                if current(request) { status = .error(error.localizedDescription) }
            }
        }
    }

    private func accept(_ hit: Hit, wrapped: Bool, request: Stamp, query: DocumentSearchQuery) async {
        do {
            let valid = try await validate(hit, query)
            guard current(request) else { return }
            guard valid else { status = .sourceChanged; return }
            activeHit = hit
            status = .found(wrapped: wrapped)
            onHit?(hit, wrapped)
        } catch is CancellationError {
        } catch {
            if current(request) { status = .error(error.localizedDescription) }
        }
    }

    private func reportProgress(_ fraction: Double?, request: Stamp) {
        guard current(request) else { return }
        guard case .searching = status else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastProgressTime >= 0.1 else { return }
        lastProgressTime = now
        status = .searching(fraction.map { min(1, max(0, $0)) })
    }
}

struct DocumentSearchQuery: Sendable, Equatable {
    var text = ""
    var caseSensitive = false
    var wholeWord = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.caseSensitive == rhs.caseSensitive && lhs.wholeWord == rhs.wholeWord
            && lhs.text.unicodeScalars.elementsEqual(rhs.text.unicodeScalars)
    }
}
