# TextSearchCore contract

`TextSearchCore` defines literal text matching semantics and coordinate-neutral
match ranges. It does not depend on AppKit, filesystems, TextBuffer, or FSearch.
`FileManagerCore` and `EditorCore` supply source adapters. `CommanderUI` owns
document navigation, wraparound, UI state, and task lifetime.

## Text and coordinates

- Matching is over Unicode scalars. Case-sensitive search compares scalar
  values exactly. Case-insensitive search uses locale-independent **full case
  folding**. The checked-in table is generated from Python 3.14's Unicode
  16.0.0 `str.casefold()` data using `scripts/generate-case-folding.py`; it
  implements the default C + F mappings in [Unicode 16.0.0 CaseFolding.txt](https://www.unicode.org/Public/16.0.0/ucd/CaseFolding.txt),
  excluding locale-specific Turkic mappings. It does not remove accents or
  normalize composed/decomposed text.
  For example, `ß` folds to `ss`, but `é` does not become `e` or `e` plus a
  combining accent.
- A match starts and ends only at original source scalar boundaries. A query
  for `ss` may match `ß`; a query for `s` cannot match half of that expansion.
- Whole-word treats Unicode letters, numbers, marks, connector punctuation,
  and the join controls U+200C/U+200D as word constituents. Both adjacent
  source scalars are inspected, including across read boundaries.
- Editor text uses LF-normalized content. In the viewer, CRLF is one LF search
  token with a two-byte source span. A bare CR remains a CR token. A query
  containing LF therefore does not match a bare CR.
- Malformed UTF-8 bytes in a viewer source are matching barriers. Query
  U+FFFD only matches the valid UTF-8 encoding of U+FFFD, never malformed
  bytes displayed as a replacement character.
- Viewer match bounds are `Int64` source byte offsets. Editor match bounds are
  `Int` UTF-16 offsets. Bounds are half-open, nonnegative, and nonempty.
  Adapters expose distinct viewer/editor hit types to prevent coordinate mixups.

## Enumeration and ownership

- All literal occurrences are eligible, including overlaps. Forward and
  backward scans enumerate the same start positions in opposite order.
- Matches may cross read boundaries. Chunk partitioning must not change the
  result set. The scanner retains bounded state rather than every occurrence.
- Wraparound belongs to document navigation. It scans disjoint start-position
  intervals, never concatenates EOF with BOF, and reports whether a result
  wrapped. `TextSearchCore` neither stores nor reports a wrap state.
- An empty query clears results without starting a worker. Callers distinguish
  found, exhausted, cancelled, and source-changed outcomes. A source read
  failure remains a source error. Content-scan progress and source revision
  checks belong to adapters; cancellation and UI task lifetime belong to the
  session. No total count is implied by finding one hit.

## Scanner API

Create `LiteralSearchMachine<Offset>(query:direction:)` for a nonempty query.
Feed `TextSearchInput.scalar` values in the requested direction, with exact
source spans; feed `.barrier` for malformed input. Reverse adapters must emit
source scalars in reverse order, while keeping each scalar's ordinary ascending
source bounds. Call `finish()` at EOF or BOF. Each `consume`/`finish` step
returns `.advance`, `.match`, or `.cancelled`. The machine emits at most one hit
per input. In whole-word mode, a hit may appear on the *next* input because
the scanner must inspect the adjacent source scalar. Barriers separate runs
and flush a pending whole-word hit.

The machine holds a KMP failure table and a ring of source spans proportional
to the folded query length. Its `isCancelled` closure is checked at the first
input and every 256 source inputs, including no-hit scans. `processedUnits`
counts inputs rather than matches. Source adapters own decoding, chunking,
revision checks, errors, and the resulting navigation interval policy.

Eligible ASCII literals can use `ASCIILiteralScanner` instead. It owns byte
matching and query-length overlap between source blocks; adapters retain their
own offset coordinates, source checks, and Unicode fallback. A failed ASCII
assumption requests a restart with the scalar matcher. `TextSearchQuery` also
provides the maximum source-scalar span of a match so adapters do not encode
case-fold expansion limits themselves.
