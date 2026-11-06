# Viewer and editor search implementation plan

Status: implementation in progress on branch `codex/viewer-editor-search`.

## Decision and scope

Implement literal search across the complete accessible file with a shared streaming matcher and separate viewer/editor source adapters. Do not build a trigram index. A scan has linear time, bounded extra memory, and supports short queries. A trigram posting index would add storage and edit invalidation work, yet still require a scan for one- and two-character queries. Benchmark the scanner before reconsidering an index.

The first release should include case-sensitive and case-insensitive literal search, whole-word mode, next/previous, wraparound, cancellation, progress, and highlighting of the active result. Regex and replacement are separate follow-ups. Arbitrary regex cannot safely be implemented by scanning fixed chunks with a guessed overlap.

Search must cover the whole file. Limit retained results and UI work, not the region searched. A first hit may be returned before a full scan completes. Do not show a total match count unless one was actually computed.

## Confirmed reference behavior

- Zed's literal `SearchQuery` uses Aho-Corasick over rope bytes. Non-ASCII case-insensitive literals use an escaped regex fallback; its regex path materializes the rope as a string. It does not use a persistent per-file trigram index in the inspected search paths: <https://github.com/zed-industries/zed/blob/main/crates/project/src/search.rs>.
- Zed project search scans candidate files, then scans matching buffers. It caps project results at 5,000 files and 10,000 ranges. Those caps do not establish a per-file size limit: <https://github.com/zed-industries/zed/blob/main/crates/project/src/project_search.rs> and <https://zed.dev/blog/nerd-sniped-project-search>.
- Far's official help assigns F7 to opening search and Shift+F7/Alt+F7 to forward/backward continuation in both viewer and editor: <https://github.com/FarGroup/FarManager/blob/master/far/FarEng.hlf.m4>. Far's viewer also uses Space for continuation; Commander currently uses Space for page down, so preserve Commander's behavior.
- Commander viewer reads through `FileContentSource`, has no whole-file line index, and supports large files with bounded reads. Its 16 MiB limit is a *display-row* limit. Editor content is in a mutable rope, uses UTF-16 coordinates, and publishes `contentVersion` changes. Archive content retains its existing expansion limit.

## Architecture and contracts

Create an independent `TextSearchCore` SwiftPM target for literal matching and text semantics. It has no AppKit, filesystem, TextBuffer, or FSearch dependency. `FileManagerCore` and `EditorCore` adapt their own sources to the matcher; `CommanderUI` owns search UI, task lifetimes, document navigation, and wraparound. This small leaf target is justified by two current consumers, not by a future universal search framework. Assign `Package.swift` and shared public API changes to one owner before parallel implementation.

Future filename/path search is a separate workflow. Its request, result, and backend contract belong in `FileManagerCore`; an eventual `FSearchClient` target implements that contract and is injected by `CommanderUI`. Dependency direction is `FSearchClient → FileManagerCore`, never the reverse. FSearch owns its indexing, query language, ranking, and transport. It must not become a dependency of viewer/editor text search. Do not add the future backend protocol or client as part of this implementation.

```text
Commander ───────→ FileManagerCore ───→ TextSearchCore
     └──────────→ EditorCore ────────→ TextSearchCore
```

Core types:

```swift
enum SearchDirection: Sendable { case forward, backward }

struct TextSearchQuery: Sendable, Equatable {
    let text: String
    let caseSensitive: Bool
    let wholeWord: Bool
}

struct TextMatch<Offset: FixedWidthInteger & Sendable>: Sendable {
    let lowerBound: Offset
    let upperBound: Offset
}
```

Keep wraparound options and `wrapped` outcomes in document navigation, and keep content-scan progress in the source adapters/session. Use `Int64` *source byte offsets* for viewer hits and `Int` *UTF-16 offsets* for editor hits. Give the public adapters distinct `ViewerSearchHit` and `EditorSearchHit` types so one coordinate system cannot be passed to the other accidentally. Return found, exhausted, cancelled, and source-changed outcomes distinctly. Empty query clears results and starts no worker.

For one literal pattern, a KMP failure table and streaming token state are enough. Keep a ring of original source spans for the query tokens. Search memory should be proportional to chunk size and query length; do not retain every occurrence. The forward and reverse implementations must enumerate the same start positions in opposite order. Cancellation checks must be based on bytes/scalars processed, including no-match files.

### Text semantics to freeze in phase 1

- Sensitive matching compares Unicode scalars exactly. Insensitive matching uses locale-independent full case folding, without accent removal or canonical normalization. Pin and test this behavior before shipping. An ASCII fast path is appropriate.
- A folded source scalar may expand (`ß` to `ss`). A candidate may begin/end only at source scalar boundaries: `ss` may match `ß`, but `s` must not match half of it.
- Whole-word boundaries use a shared predicate across adapters: letters, numbers, marks, connector punctuation, and join controls. Inspect adjacent source scalars, even across chunk boundaries.
- Invalid UTF-8 in the viewer is a matching barrier. U+FFFD in the query matches an actual U+FFFD encoding, not arbitrary malformed input that happens to render as `�`.
- Match candidates may cross read boundaries. The editor's LF-normalized text uses LF. In the viewer, CRLF may be treated as one LF search token while retaining its two-byte source span; specify and test bare-CR behavior separately.
- Do not generate a match by concatenating EOF and BOF during wraparound.

## Source adapters

### Editor

Add `EditorSearchSnapshot.swift` and a main-actor `EditorDocument.makeSearchSnapshot()` method. The worker must receive immutable, sendable content; it must never read the live document or selection concurrently. The pinned TextBuffer dependency has `TransferableUndoable(buffer).sendableSnapshot()`, which shares a copy-on-write rope instead of flattening the whole document. Wrap dependency types privately so the `EditorDocument` boundary remains project-owned.

The adapter must return the *actual* UTF-16 range of each chunk. `EditorDocument.text(in:)` expands requested slices to composed-character boundaries; advancing by the requested chunk length can duplicate or skip text. Advance by the returned length from a known grapheme boundary. Test very long combining sequences, which can exceed a requested chunk size. If strict bounded chunks are required, add a raw scalar-aligned rope API rather than assuming the current API is exact.

Keep both the exact match range (for next/previous continuation) and a grapheme-expanded selection range (for caret safety and display). Tag each hit with `contentVersion`. After edits, undo, or redo, cancel the worker and discard old results. Do not try to shift cached matches incrementally in the first version: a nearby edit can change whole-word boundaries and create a match across the edit.

### Viewer

Retain the opened `FileContentSource` in `FileViewerCoordinator` and let `ViewerSearchSource` read it directly in bounded chunks (start at 64 KiB). Do not hold `FileViewerDocument`'s page serialization gate for an entire scan. Carry partial UTF-8 and CRLF state across reads. For reverse search, read blocks backward, decode each block forward, and emit complete tokens in reverse, with explicit ownership at boundaries to avoid duplicates.

Unknown-length forward search should read until EOF without first forcing `length()`. Reverse-from-EOF may require `length()` and can trigger archive preparation; make it cancellable and show indeterminate progress. Capture source metadata at search start and revalidate during scanning and before reveal. A changed revision or known size invalidates the search. Sources with no revision cannot promise an immutable snapshot; recheck the candidate bytes before reveal. Surface existing archive source errors.

Add `ViewerCommand.reveal(byteOffset: Int64)`. In text mode, align the hit to a scalar and locate its display row; in hex mode, align to its 16-byte row. Preserve the active byte range when switching text/hex or wrap mode. A valid hit in an unwrapped logical line over 16 MiB must not close the viewer through the existing row error path; switch to wrapped display for reveal or present an explicit hex fallback.

Viewer highlighting must map original source byte spans to rendered cells during `readRow`'s decoding pass. `sourceText` replaces malformed bytes, and tabs/control characters change display width, so derived byte lengths from rendered text are incorrect. Highlight the matching bytes in both hex and ASCII regions of hex mode; centralize hex layout coordinates with `HexRowFormatter`.

## Search session and navigation

Use one `@MainActor` search controller per open viewer/editor. Its request stamp contains a session UUID and monotonically increasing generation. Every query/options change, direction request, document mutation, search dismissal, or document close cancels dependent work and advances the generation. Explicitly cancel detached tasks, and fence every result/progress callback with the stamp and document revision/version. Throttle progress messages.

Keep viewer search work separate from `FileViewerCoordinator.task` and its opening dialog: cancelling that task currently closes the viewer. A long search must not prevent scrolling.

Navigation rules:

1. Opening search starts from the editor caret/selection start or viewer's current byte position. The first search includes this anchor.
2. Continue forward takes the first match whose *start* is strictly greater than the current exact match start; continue backward takes the greatest strictly smaller start. This handles overlapping matches symmetrically.
3. Manual caret or viewer navigation sets a new origin. A changed query restarts from that user origin, rather than from a stale hit of the old query.
4. Wrap scans at most two disjoint start-position intervals and marks the wrapped result. Start-position restrictions apply even if a match extends beyond an interval boundary.
5. A single result may be returned again on continuation with a wrapped indicator. No-match preserves the user's position.

Show `Searching…`, `Wrapped`, `No matches`, and source errors accurately. Avoid a fabricated `1 of N` count. Search progress for unknown-length sources is indeterminate.

## UI and key behavior

Use a shared compact search surface with a native AppKit text field for paste, IME, and accessibility. The query/options/session model must be independent of the surface. Add `7 Search` to both footer bars and support clicking it.

| Action | Keys |
| --- | --- |
| Open/focus search | F7, Command+F |
| Continue forward | Shift+F7, Command+G |
| Continue backward | Option+F7, Command+Shift+G |
| Submit/continue from field | Enter / Shift+Enter |
| Dismiss search and restore content focus | Escape |

Handle modifiers before the generic function-key switch. When search is active, Escape dismisses it without closing the document. Preserve the editor's existing multi-caret Escape behavior after search is inactive. Search highlight is separate from viewer mouse selection; existing selection takes visual precedence. Never let search modify editor undo history or mark an untouched document modified.

## Handoff sequence

| Phase | Files / owner boundary | Depends on | Completion evidence |
| --- | --- | --- | --- |
| 1. Contracts | `Package.swift`, `Sources/TextSearchCore/*`, `Tests/TextSearchCoreTests/*` | None | Public coordinates, Unicode, overlap, wrap, and errors documented; module builds |
| 2. Matcher | `TextSearchCore/LiteralSearchMachine.swift`, case-fold helper and tests | 1 | Partition-invariant forward/reverse results, bounded memory, cancellation |
| 3A. Viewer adapter | `FileManagerCore/ViewerSearchSource.swift` and core tests | 2 | Full source coverage, unknown EOF, >4 GiB offsets, revision invalidation |
| 3B. Editor adapter | `EditorCore/EditorSearchSnapshot.swift`, minimal `EditorDocument.swift`, tests | 2 | Copy-on-write snapshot, UTF-16 mapping, grapheme-safe chunks and selection |
| 4. Shared UI/session | `Commander/DocumentSearchController.swift`, search surface, focused UI tests | 1 and adapter contracts | Key routing, focus, cancellation, stale callback fencing |
| 5A. Viewer integration | `FileViewerDocument.swift`, viewer projection, `TerminalFileViewer.swift`, `FileViewerCoordinator.swift` | 3A, 4 | Reveal/highlight in wrap, unwrap, hex, long lines and malformed text |
| 5B. Editor integration | editor search controller, `TerminalFileEditor.swift`, `FileEditorCoordinator.swift` | 3B, 4 | Safe selection/reveal, mutation invalidation, IME and undo behavior |
| 6. Integration and performance | README, focused regressions, release benchmark | All | Existing tests pass; latency and peak extra memory measured |

Phases 3A and 3B can run in parallel after the core contract stabilizes. Viewer and editor UI integration can likewise proceed independently after phase 4. Avoid simultaneous ownership of the same UI file. Have the phase-1 owner handle changes to `Package.swift` and shared public types.

## Required verification

Core: empty/start/end/no-hit cases; a query longer than a chunk; match crossing every chunk boundary; overlaps (`aaa` in `aaaaa`); reverse equals reversed forward; wrap once; whole-word across boundaries; UTF-8 splits; scalar folding expansions; composed/decomposed text; emoji ZWJ; malformed bytes as barriers; cancellation during a no-hit scan.

Editor: snapshot remains stable after replace/undo/redo; version rejects late hits; chunk cursors advance by actual returned length; selection never splits a grapheme; exact ranges drive continuation; multi-caret/IME transitions; search leaves undo and dirty state unchanged; close cancels callbacks.

Viewer: tail hit past small-file thresholds; synthetic offsets beyond 4 GiB; bounded read sizes and memory; unknown size; archive failure/cancel; changed-size and same-size replacement; search does not block scrolling; reveal in text/hex/wrapped/unwrapped modes, including tabs, CRLF, malformed UTF-8 and a >16 MiB line. An optional real sparse-file benchmark can scan an 8 GiB tail marker without making the unit suite slow.

Release benchmarks: time to first hit, no-hit throughput, reverse-near-caret latency, cancellation latency, snapshot creation time, and peak extra memory. Test ASCII logs, Unicode, dense matches, long single lines, and a large local file. Measure cached and cold-disk runs separately. Optimize only a measured bottleneck.

## Future file search with FSearch

The intended FSearch is <https://github.com/noahdunnagan/fsearch>, a Rust file-search engine with filename ranking, content search, persistent indexes, and a JSON-lines socket/stdio interface. It is not currently a dependency of this package. When Find Files is implemented, put its application-owned `FileSearchRequest`, `FileSearchResult`, and small `FileSearching` protocol in `FileManagerCore`; implement the protocol in a separate `FSearchClient` target. Keep FSearch wire models private to that client. A recursive `VirtualFileSystem` backend can later support archive or other scopes that FSearch cannot address. Reuse only small UI field/styling components where useful; file queries, ranked results, and index progress are different from in-document literal matches and byte/UTF-16 locations.

The reviewed FSearch content implementation currently indexes ordinary files up to 1 MiB and repository files up to 10 MiB, and its `match_open`/`matches_in` path rejects files over 10 MiB. It also cannot inspect an unsaved editor rope or an open archive-member source through its disk-oriented API. These are reasons to keep F7 document search on the local streaming matcher. Recheck limits and pin the helper/protocol version at integration time: <https://github.com/noahdunnagan/fsearch/blob/main/src/content.rs>, <https://github.com/noahdunnagan/fsearch/blob/main/src/engine.rs>, <https://github.com/noahdunnagan/fsearch/blob/main/src/server.rs>.

Future “find text in files” can compose candidate discovery, content verification, and grouped file results. If FSearch supplies candidates, its index coverage and exclusions must be visible in the search contract; a mode promising all accessible files needs a fallback for uncovered files and a way to include unsaved buffers. Do not infer completeness from a finite candidate list without checking that coverage.
