# Document search baseline

Measured on 2026-10-24 on an arm64 Mac with `swift test -c release
--disable-sandbox --no-parallel`. A temporary, environment-gated benchmark
test built synthetic editor documents and local viewer files; the benchmark
test files were removed after measurement. Each case ran once per process, so
these are indicative latency measurements, not statistical estimates.

The ASCII, long-line, and dense cases contained about 2 MB of text. The
Unicode case repeated `Жe` plus a combining accent 500,000 times (1.5 million
UTF-16 units, 2.5 MB UTF-8). Tail-hit cases ended in `needle`; dense text was
all `a` and searched for `aaa`. No-hit scans searched for `absent!`. The
reverse test started at the last UTF-16 unit or byte. Chunk size was 64 KiB.

| Case | Editor snapshot | Editor first tail hit | Editor no hit | Editor reverse near tail | Viewer first tail hit | Viewer no hit, first/warm | Viewer reverse near tail |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ASCII | 0.077 ms | 864 ms | 874 ms | 0.49 ms | 782 ms | 780 / 784 ms | 2.25 ms |
| Unicode | 0.002 ms | 782 ms | 720 ms | 93 ms | 754 ms | 614 / 622 ms | 1.59 ms |
| Long line | 0.001 ms | 866 ms | 871 ms | 0.34 ms | 778 ms | 774 / 775 ms | 2.20 ms |
| Dense | 0.002 ms | 0.24 ms | 868 ms | 0.34 ms | 2.55 ms | 779 / 778 ms | 2.22 ms |

No-hit throughput was about 2.3 MB/s for the ASCII editor and 2.6 MB/s for
the ASCII viewer. A viewer scan cancelled by a monotonic 5 ms deadline returned
`cancelled` in 5.0–5.1 ms across all four cases. A snapshot shares the editor
rope by copy-on-write; creation was below 0.1 ms in these cases. The unusually
high Unicode editor reverse time was traced to grapheme selection expanding
all the way to BOF despite an independent break near the tail. After finding
that local break, the same reverse-tail case took 0.449 ms instead of 93.99 ms.

For a larger local-file check, a 64 MiB ASCII file was written in 1 MiB chunks
and ended with `needle` (67,108,870 bytes total). The first tail hit took
26.418 s and the complete no-hit scan took 26.357 s, or about 2.55 MB/s. The
process RSS high-water mark rose by 8.67 MB during the first scan and did not
rise further on the second scan. An 8 MiB editor no-hit scan with a monotonic
5 ms cancellation deadline returned `cancelled` after 5.075 ms. These larger
measurements used the same release build and cached local filesystem; the
temporary benchmark tests were removed afterward.

The timings above were measured before exporting the matcher’s `Int` and
`Int64` specializations. An isolated 2 million-input release matcher benchmark
improved from roughly 781 ms to 143–156 ms with those specializations. In a
repeat of the 64 MiB local-file test after specialization, tail hit took
4.784 s and no-hit took 4.795 s (about 14.0 MB/s, 5.5× faster). RSS high-water
rose by 9.16 MB during the first scan and another 16 KiB during the second.
An independent release harness measured the 2 million-unit ASCII editor
no-hit scan at 152 ms with sensitive matching and 157 ms insensitive.

`getrusage` high-water RSS rose by up to about 10 MB during editor search and
3.4 MB during viewer search in the small cases. This is a coarse process-wide measure and depends
on allocator reuse and earlier cases. The first and repeated viewer scans
used the same source and differed little. Files had just been written and were
likely in the OS page cache, so these numbers do **not** represent cold-disk
I/O. No page-cache eviction was attempted.

The editor's bounded-anchor test also checks that a no-hit scan beginning near
EOF performs under 100 cancellation probes on a two-million-unit document.
Before bounded starts, it scanned the entire prefix. Matching and whole-word
tests cover case-fold expansion and a surrogate-pair anchor.

## Bottleneck investigation

A separate release benchmark scanned a cached 16 MiB local file filled with
ASCII `x`, searching for absent `absent!`. The same source bytes were also
served by an in-memory actor. These measurements used temporary test-only
instrumentation, which was removed after the run.

| Operation | Elapsed time |
| --- | ---: |
| Full viewer scan, local file / in-memory source | 1.23–1.27 / 1.23–1.26 s |
| Read the whole local file in 64 KiB blocks, including metadata checks | 3.4–3.7 ms |
| Decode bytes and materialize scalar inputs within the full scan | 0.58–0.60 s |
| Feed those inputs to `LiteralSearchMachine` within the full scan | 0.64–0.66 s |
| Raw `Data.range(of:)` absent-pattern search over the entire 16 MiB buffer | 1.6 ms |
| Raw `Data.range(of:)` over 64 KiB blocks | 2.6 ms |

Changing the viewer block size among 16 KiB, 64 KiB, and 1 MiB barely changed
the full-scan time. Thus disk I/O, actor hops, metadata checks, and block size
are not material bottlenecks in this cached case. Nearly all time is spent
turning bytes into scalar records and processing each scalar. The matcher
currently computes word classification and case-fold arrays for every scalar
even when whole-word or case-insensitive matching is disabled.

The raw `Data.range(of:)` figures are only a lower bound for a specialized
path, not equivalent search behavior: they omit Unicode case folding, CRLF
normalization, word boundaries, malformed UTF-8 barriers, chunk overlap,
source validation, and cancellation. They motivated a bounded byte path for
non-whole-word ASCII queries without CR or LF, with the scalar matcher kept
for other cases. Tests cover chunk-spanning hits, source changes, both
directions, and Unicode fallback.

The viewer now uses that bounded byte path for eligible ASCII queries. For
case-insensitive search it lowercases ASCII blocks, and restarts the scalar
scan if it encounters a non-ASCII byte because Unicode folding may produce an
ASCII match. A subsequent cached 16 MiB local-file release run with the same
absent query measured 88.6 ms case-insensitive and 4.9 ms case-sensitive;
forcing the scalar path with whole-word mode took 1.20 s. These are one-run
synthetic comparisons, not cold-disk or representative-corpus results.

Editor snapshots use the same query eligibility rules on ASCII rope slices.
On a separate 16 MiB ASCII snapshot, the no-hit scan measured 103.5 ms
case-insensitive and 55.5 ms case-sensitive; the whole-word scalar path took
1.29 s. The fast paths retain bounded chunk overlap and fall back to Unicode
search when an ASCII assumption does not hold.

Repeating the 64 MiB local-file test with the fast path took 0.418 s for the
case-insensitive tail hit and 0.414 s for a case-insensitive no-hit scan,
versus 4.78–4.80 s for the earlier scalar path. A case-sensitive no-hit scan
took 0.022 s. The file had just been written, so these are warm-cache results.

## Large-file check (2026-11-06)

A release-mode, environment-gated temporary test measured the current viewer
and editor implementations on this arm64 Mac. Files were filled with ASCII
`x` and ended with one `needle`; the absent query was `absent!`. The
test searched forward from offset zero to the tail, forward for a missing
query, and backward from the tail hit. Each case ran twice. Viewer files were
written immediately before scanning, so they were likely in the OS page
cache. The temporary test source and files were removed afterward.

| Surface and size | Mode | Tail hit | No hit | Backward from tail |
| --- | --- | ---: | ---: | ---: |
| Viewer, 100 MiB | Case-sensitive | 0.031–0.032 s | 0.030–0.031 s | 0.012 ms |
| Viewer, 100 MiB | Case-insensitive | 0.613–0.616 s | 0.607–0.611 s | 0.37–0.39 ms |
| Viewer, 1 GiB | Case-sensitive | 0.325–0.329 s | 0.304–0.318 s | 0.012 ms |
| Viewer, 1 GiB | Case-insensitive | 6.316–6.339 s | 6.295–6.340 s | 0.37–0.40 ms |
| Editor, 100 MiB | Case-sensitive | 0.329–0.333 s | 0.325–0.327 s | 0.22 ms |
| Editor, 100 MiB | Case-insensitive | 0.610–0.610 s | 0.606–0.611 s | 0.40–0.43 ms |

Building the synthetic 100 MiB editor document and its copy-on-write search
snapshot took 1.065 s, measured separately from search. These measurements do
not include opening a real file into the editor, scheduling from the UI,
selection reveal, syntax highlighting, or rendering. They also do not measure
cold-disk reads, mixed Unicode, whole-word mode, or an editor document of
1 GiB. Whole-word mode and some Unicode queries use the slower scalar matcher;
the fast-path numbers must not be applied to those cases. Two runs on a
repetitive synthetic corpus are latency samples, not a stable distribution.

## Shared byte scanner follow-up (2026-11-06)

After moving byte matching into `TextSearchCore`, ASCII-insensitive search
folds each source block in one pass into one owned buffer and searches only
query-length boundary windows plus the block. The same warm viewer EOF-hit
benchmark, repeated twice in a release build, measured:

| Size | Case-sensitive | Case-insensitive |
| --- | ---: | ---: |
| 100 MiB | 0.029–0.031 s | 0.071 s |
| 1 GiB | 0.310–0.312 s | 0.732–0.735 s |

The preceding table is the pre-refactor baseline. This follow-up did not
remeasure the editor, whole-word mode, Unicode fallback, or cold-disk reads.
