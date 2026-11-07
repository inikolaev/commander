# Search baseline before SIMD

Measured 2026-11-07 on a MacBook Pro M4 Pro (14 CPU cores, 48 GB RAM), arm64,
macOS. Branch `codex/simd-search` started at merged `main` commit `2c2163d`.
The release benchmark was built with
[`build-search-benchmark-offline.sh`](../../scripts/build-search-benchmark-offline.sh)
using `swiftc -O -whole-module-optimization` for the current project modules;
the binary's source hashes and cached dependency inputs are preserved in
[baseline provenance](profiles/search-baseline-provenance.txt). A normal SwiftPM release
build was attempted but dependency checkout resolution stalled on missing Git
objects; the offline script rebuilds every search module from this branch and
reuses cached `ArchiveCore`, `CFileCopy`, and external dependency objects. Use
the same build path for comparisons.

The fixtures are deterministic ASCII text with a newline every 128 bytes and
unique 6-byte and 64-byte literals near BOF, midpoint, and EOF. An absent
literal covers a complete no-hit scan. Cases in the
[`run-search-matrix.py`](../../scripts/run-search-matrix.py) matrix also include
reverse scans and searches. Each case ran in a fresh process. The first timed
iteration is discarded as warmup; the table shows medians of the remaining
iterations (seven for 100 MiB, five for 1 GiB, three for 10 GiB). Search is
timed separately from file open and editor document/snapshot construction.
Files had been generated recently and were likely cached by macOS. These are
warm-cache latency measurements, not cold-disk throughput. Profiling was done
in separate runs.

| Size | Surface | Scan only | CI end short | CI end long | CI absent | CS end long |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 100 MiB | Viewer | 18.8 ms | 68.6 ms | 60.0 ms | 109.2 ms | 20.4 ms |
| 100 MiB | Editor | 9.4 ms | 59.7 ms | 52.9 ms | 99.8 ms | 21.7 ms |
| 1 GiB | Viewer | 197 ms | 705 ms | 624 ms | 1,120 ms | 210 ms |
| 1 GiB | Editor | 99 ms | 629 ms | 546 ms | 1,038 ms | 230 ms |
| 10 GiB | Viewer | 1.98 s | 7.37 s | 6.22 s | 11.50 s | 2.19 s |

CI means case-insensitive, CS case-sensitive. Scan only traverses and
materializes the same bounded source blocks but does no matching. The viewer
uses `LocalFileContentSource`; the editor control uses the same raw rope slices
and UTF-8 `Data` materialization as its ASCII search path. Search itself also
performs query preparation, source checks, matching, and hit construction.
The 100 MiB/1 GiB CI absent search costs about 5.7–5.8× the viewer scan
control and 10.5–10.7× the editor scan control. A near-BOF hit takes only
roughly 18–52 microseconds because it does not traverse the entire file;
its latency should not be presented as whole-file throughput. Midpoint and
reverse cases, setup times, expected offsets, and correctness checks were
measured with the same benchmark harness. Generated JSON Lines output is kept
outside the repository; this report records the summarized results.

The 1 GiB editor process peaked at **3.82 GB resident memory** (`/usr/bin/time
-l`). A 10 GiB editor document would approach 38 GB if that ratio holds,
before other applications and page cache, so a 10 GiB editor run was withheld
to avoid heavy swapping on this 48 GB machine. The viewer remains bounded in
memory and was measured at 10 GiB. This is an editor storage limitation,
separate from the search scanner.

## Sampled profiles

`sample` collected 1 ms stack samples during repeated 100 MiB runs, separate
from the latency measurements. Representative flame graphs are clickable HTML.

| Profile | Flame graph | Main observation |
| --- | --- | --- |
| Viewer CI end hit | [HTML](profiles/search-viewer-ci-baseline.html) | 58.0% of search samples in `ASCIILiteralQuery.preparedBlock`; 13.7% in `Data.range(of:)` |
| Editor CI end hit | [HTML](profiles/search-editor-ci-baseline.html) | 65.9% in block preparation; 17.0% in `Data.range(of:)` |
| Viewer scan only | [HTML](profiles/search-viewer-scan-baseline.html) | Dominated by `LocalFileContentSource.read` and `Data` copying |
| Editor scan only | [HTML](profiles/search-editor-scan-baseline.html) | Dominated by `TextRope.content(in:)` and UTF-8 materialization |

These are inclusive sample shares, not exact cycle attribution. The
case-insensitive ASCII block preparation is the first optimization target.
Whole-word and Unicode fallback use the scalar matcher; this baseline matrix
does not claim to measure their speed.
