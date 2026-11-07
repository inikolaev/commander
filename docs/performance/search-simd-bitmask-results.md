# SIMD high-bit check: second implementation step

The first [SIMD implementation](search-simd-results.md) still called an
out-of-line `SIMD.min()` reduction while checking each 16-byte block for
non-ASCII bytes. This step reinterprets that loaded block as two 64-bit words
and tests their byte high bits with one mask. It changes only the private
block preparation path. Search contracts, Unicode fallback, and the shared
scanner remain the same.

The fixture files were reused unchanged. The same release build procedure,
matrix, iteration counts, warmup exclusion, and unprofiled timing method were
used. The [build provenance](profiles/search-simd-bitmask-provenance.txt)
records source and binary hashes. Values are medians; `×` is first-SIMD time
divided by this step's time.

| Size | Surface | Scan only | CI end short | CI end long | CI absent | CS end long |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 100 MiB | Viewer | 19.1 → 18.6 ms (1.03×) | 40.7 → 31.3 ms (1.30×) | 29.5 → 23.6 ms (1.25×) | 80.2 → 75.0 ms (1.07×) | 20.6 → 20.2 ms (1.02×) |
| 100 MiB | Editor | 9.2 → 9.2 ms (1.00×) | 27.3 → 24.2 ms (1.12×) | 19.9 → 14.4 ms (1.38×) | 70.2 → 65.7 ms (1.07×) | 13.0 → 13.1 ms (0.99×) |
| 1 GiB | Viewer | 193 → 190 ms (1.02×) | 386 → 324 ms (1.19×) | 304 → 258 ms (1.18×) | 819 → 777 ms (1.05×) | 209 → 210 ms (1.00×) |
| 1 GiB | Editor | 98 → 98 ms (1.00×) | 293 → 238 ms (1.23×) | 212 → 152 ms (1.39×) | 726 → 675 ms (1.08×) | 140 → 136 ms (1.03×) |
| 10 GiB | Viewer | 1.90 → 1.91 s (0.99×) | 3.93 → 3.34 s (1.18×) | 3.05 → 2.45 s (1.25×) | 8.22 → 7.67 s (1.07×) | 2.10 → 2.07 s (1.02×) |

The scan-only and viewer case-sensitive controls remain close to their
first-SIMD times. All 496 iteration records report `correct: true`. Full
results include beginning, middle, end, absent, and reverse searches:

- [100 MiB JSONL](profiles/search-simd-bitmask-100mib.jsonl)
- [1 GiB JSONL](profiles/search-simd-bitmask-1gib.jsonl)
- [10 GiB viewer JSONL](profiles/search-simd-bitmask-10gib-viewer.jsonl)

The 10 GiB editor case remains unmeasured because of the memory estimate in
the [baseline report](search-simd-baseline.md). These are warm-cache runs of
one deterministic ASCII corpus, not cold-disk or representative text-corpus
measurements. The fixture generator checks file size and manifest metadata on
normal reruns, and writes large files only when missing or explicitly forced.

## Separate profiles

The profiler sampled a separate 100 MiB case-insensitive end-short run at
1 ms intervals. Interactive flame graphs: [viewer](profiles/search-viewer-ci-bitmask.html)
and [editor](profiles/search-editor-ci-bitmask.html). Raw call trees, folded
stacks, SVG, JSON, and top-function summaries are next to the HTML files.

`ASCIILiteralQuery.preparedBlock` accounted for 13.2% of inclusive viewer
search samples and 16.5% of editor samples, down from 26.2% and 36.2% in the
first-SIMD profiles. The out-of-line `SIMD.min()` reduction no longer appears.
Sampling shares from separate runs are diagnostic and do not directly measure
time saved. The largest remaining sampled costs include file reads and data
matching in the viewer, and data matching and rope extraction in the editor.

## Commit sequence

1. Establish the fixture generator, benchmark matrix, scan controls, baseline
   numbers, and separate flame graphs.
2. Vectorize ASCII validation and folding in 16-byte blocks; run correctness
   checks, the full matrix, and profiles.
3. Inline the high-bit check; repeat the same checks, matrix, and profiles.

The work stayed within a private implementation detail, so it did not require
changing public contracts. A broader redesign of editor storage or search
would be a separate project with its own baseline and memory budget.
