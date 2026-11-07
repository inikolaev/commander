# SIMD block preparation: first comparison

This is the first implementation step after the [pre-SIMD baseline](search-simd-baseline.md).
`ASCIILiteralQuery.preparedBlock` validates 16 bytes at a time and folds ASCII
`A...Z` in SIMD lanes. The shared byte matcher, chunk overlap, Unicode
fallback, adapters, and public search contracts remain unchanged.

The same generated files, benchmark matrix, M4 Pro machine, release compiler
flags, and warmup policy were used before and after. The post-change binary's
[provenance](profiles/search-simd-provenance.txt) records source and binary
hashes. Times below are medians from separate, unprofiled runs; `×` is
baseline time divided by SIMD time.

| Size | Surface | Scan only | CI end short | CI end long | CI absent | CS end long |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 100 MiB | Viewer | 18.8 → 19.1 ms (0.98×) | 68.6 → 40.7 ms (1.69×) | 60.0 → 29.5 ms (2.03×) | 109.2 → 80.2 ms (1.36×) | 20.4 → 20.6 ms (0.99×) |
| 100 MiB | Editor | 9.4 → 9.2 ms (1.02×) | 59.7 → 27.3 ms (2.19×) | 52.9 → 19.9 ms (2.66×) | 99.8 → 70.2 ms (1.42×) | 21.7 → 13.0 ms (1.67×) |
| 1 GiB | Viewer | 197 → 193 ms (1.02×) | 705 → 386 ms (1.83×) | 624 → 304 ms (2.05×) | 1,120 → 819 ms (1.37×) | 210 → 209 ms (1.00×) |
| 1 GiB | Editor | 99 → 98 ms (1.01×) | 629 → 293 ms (2.15×) | 546 → 212 ms (2.57×) | 1,038 → 726 ms (1.43×) | 230 → 140 ms (1.64×) |
| 10 GiB | Viewer | 1.98 → 1.90 s (1.04×) | 7.37 → 3.93 s (1.87×) | 6.22 → 3.05 s (2.04×) | 11.50 → 8.22 s (1.40×) | 2.19 → 2.10 s (1.04×) |

The editor's case-sensitive path also speeds up because it must validate
ASCII before using byte positions as UTF-16 positions. The viewer's
case-sensitive path passes bytes through without that check, so it is an
effective unchanged-path control. The scan-only controls are close to their
baseline values. One 100 MiB viewer case-sensitive short-query run was 7.7%
slower despite using this unchanged path; the corresponding 1 GiB and 10 GiB
long-query controls stayed within about 4%, so this small-case difference is
reported as observed variation, not attributed to SIMD. Every one of the 496
post-change iteration records reports
`correct: true`; the first iteration of each case is excluded from the
medians. Full case data, including BOF, midpoint, reverse, setup time, and
per-iteration spread:

- [100 MiB JSONL](profiles/search-simd-100mib.jsonl)
- [1 GiB JSONL](profiles/search-simd-1gib.jsonl)
- [10 GiB viewer JSONL](profiles/search-simd-10gib-viewer.jsonl)

The 10 GiB editor case remains unmeasured for the memory reason described in
the baseline report. These measurements are warm-cache samples of the
deterministic fixture, not a broad corpus or cold-disk estimate.

## Post-change profiles

The profiler was run separately from timing, using the same 100 MiB
case-insensitive end-short query and 1 ms sampling interval. Interactive
flame graphs: [viewer](profiles/search-viewer-ci-simd.html) and
[editor](profiles/search-editor-ci-simd.html). Raw sample call trees, folded
stacks, SVG, JSON, and top-function summaries are alongside the HTML files.

Block preparation fell from 58.0% to 26.2% of inclusive viewer search
samples, and from 65.9% to 36.2% of editor samples. Foundation byte matching
and source traversal now have larger shares. The SIMD `any` reduction appears
as an out-of-line `specialized SIMD<>.min()` call in 8.1% of viewer and 11.5%
of editor samples. These shares describe samples in each separate profile;
they cannot be subtracted to obtain exact time saved.
