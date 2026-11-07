# Literal matcher experiments

The [SIMD search work](search-simd-bitmask-results.md) leaves substring
matching in Foundation's `Data.range(of:)` path. Its Boyer–Moore implementation
accounted for 30.9% of viewer and 44.6% of editor samples in the final
100 MiB case-insensitive end-short profiles. This follow-up makes the byte
matcher selectable in the benchmark while the normal viewer and editor APIs
continue to use Foundation. The selector is passed into the shared scanner;
it does not affect ASCII preparation, Unicode fallback, chunk overlap, or
source-coordinate handling.

## Experiment 1: Darwin `memmem`

The first candidate calls Darwin `memmem` for forward searches and keeps
Foundation for reverse searches. It is available only through the benchmark
selector. The same binary, 100 MiB fixture, warmup policy, and unprofiled
matrix were used for both choices. Values below are medians in milliseconds;
lower is better.

| Case-insensitive 100 MiB search | Foundation | Darwin `memmem` |
| --- | ---: | ---: |
| Viewer end-short | 34.1 | 71.8 |
| Viewer end-long | 25.1 | 70.3 |
| Viewer absent | 76.0 | 69.6 |
| Editor end-short | 22.6 | 59.8 |
| Editor end-long | 14.6 | 60.6 |
| Editor absent | 65.7 | 59.9 |

All 44 scenarios and 352 iteration records in each matrix were correct.
Full results include beginning/middle/end, case-sensitive, and reverse cases:
[Foundation JSONL](profiles/search-matcher-foundation-100mib.jsonl),
[memmem JSONL](profiles/search-matcher-memmem-100mib.jsonl), and
[build provenance](profiles/search-matcher-memmem-provenance.txt).

The separate mixed and adversarial corpus checks show the same pattern for
multi-byte queries. On a reusable 16 MiB mixed text file, `memmem` took
12.9 versus 6.2 ms for the viewer end hit, and 11.4 versus 4.9 ms for the
editor. A repeated-text near miss (`xxxyxx` in a mostly `x` file) took
190.5 versus 105.3 ms in the viewer, and 181.5 versus 95.7 ms in the editor.
The one-byte absent query was an exception: 24.4 versus 45.8 ms in the
viewer and 15.2 versus 36.3 ms in the editor. All 48 extra scenarios and
384 iteration records were correct; see the [extra JSONL](profiles/search-matcher-extra-memmem.jsonl).

The mixed file is made by `scripts/generate-matcher-corpus.py` only if
missing. `scripts/run-matcher-cases.py` runs the additional cases. Neither
script is invoked by CI. The existing 100 MiB/1 GiB/10 GiB files were reused
without regeneration.

The candidate is not promoted to the production default: it regresses most
multi-byte cases substantially. We skipped 1 GiB and 10 GiB `memmem` runs
after the 100 MiB and mixed-corpus results established that loss. Reverse
search intentionally remains Foundation for this candidate.

The selector itself was checked by alternating the previous benchmark binary
with the new binary selecting Foundation, twice each, for six 100 MiB end-hit
and absent cases (21 iterations per invocation; first discarded). New/old
median ratios ranged from 0.976 to 1.003, with no measurable regression in
the normal path.

## Experiment 2: short-pattern SIMD filter

The second candidate uses 16-byte SIMD comparisons to find possible starts
for one- to 16-byte ASCII literals, then checks the full literal with `memcmp`.
It precomputes the filter only when this forward matcher is selected. Longer
and multi-byte uniform literals, small buffers, and reverse searches use Foundation.
After eight failed candidate checks across a scan, it searches the unexamined
remainder with Foundation and uses Foundation for subsequent blocks. This
limits dense near-miss work without changing overlap or Unicode fallback.

The final release binary passed 28 `TextSearchCore` tests and 62 focused
viewer/editor correctness scenarios. The paired 100 MiB matrices each passed
44 scenarios and 352 iteration records. The 1 GiB matrices each passed 18
scenarios and 108 iteration records; the 10 GiB viewer matrices each passed
nine scenarios and 36 iteration records. The mixed and adversarial matrix
passed 88 scenarios and 704 iteration records. Every recorded search result
was correct.
Each process's first iteration was excluded from the medians below. The
1 GiB and 10 GiB measurements preceded a final change that skipped SIMD
filter setup for Foundation and ineligible queries; the matching loop did not
change. The 100 MiB and mixed measurements use the final binary.

| Case-insensitive forward search | Foundation | SIMD | Change |
| --- | ---: | ---: | ---: |
| 100 MiB viewer middle-short | 16.73 ms | 14.82 ms | −11% |
| 100 MiB viewer end-short | 33.94 ms | 30.70 ms | −10% |
| 100 MiB editor middle-short | 11.77 ms | 9.99 ms | −15% |
| 100 MiB editor end-short | 23.42 ms | 20.03 ms | −14% |
| 1 GiB viewer end-short | 346.04 ms | 301.75 ms | −13% |
| 1 GiB editor end-short | 241.07 ms | 199.46 ms | −17% |
| 10 GiB viewer end-short | 3458.87 ms | 3173.91 ms | −8% |

The 100 MiB scan-only controls were 20.04 ms for the viewer and 9.64 ms for
the editor. Thus the viewer end-short search cost 13.90 ms above scan with
Foundation and 11.55 ms with SIMD; the editor cost 13.78 and 10.12 ms above
scan, respectively. These differences include the same case-insensitive
preparation in both matchers.

Additional files test less uniform content and worst-case candidate density:

| Forward search | Foundation | SIMD |
| --- | ---: | ---: |
| Mixed 16 MiB viewer short tail hit | 10.17 ms | 10.30 ms |
| Mixed 16 MiB editor short tail hit | 8.82 ms | 9.01 ms |
| Mixed 16 MiB viewer short absent | 11.09 ms | 4.57 ms |
| Mixed 16 MiB editor short absent | 9.56 ms | 3.18 ms |
| Repeated 100 MiB viewer near miss | 106.38 ms | 30.10 ms |
| Repeated 100 MiB editor near miss | 101.25 ms | 19.95 ms |
| Periodic 16 MiB viewer near miss | 9.90 ms | 10.17 ms |
| Periodic 16 MiB editor near miss | 7.92 ms | 8.06 ms |

The periodic corpus is an `ab` sequence; its near-miss literal triggers the
adaptive fallback. The generator creates the mixed and periodic files only
when missing, and validates a reused periodic file's contents. The existing
100 MiB, 1 GiB, and 10 GiB fixtures were not regenerated. Benchmark scripts
remain manual and are not in CI.

The candidate is kept benchmark-selectable and Foundation remains the
production default. The small mixed-text and periodic losses may be noise,
but the evidence does not establish that selecting SIMD for every eligible
literal avoids regressions. Length alone does not distinguish the winning
and losing workloads. The enum selector gives future candidates, including
Aho-Corasick variants, the same scanner and adapter path without adding a
public matcher contract or per-byte protocol dispatch.

Raw runs: [100 MiB Foundation](profiles/search-matcher-simd-foundation-100mib.jsonl),
[100 MiB SIMD](profiles/search-matcher-simd-100mib.jsonl),
[1 GiB Foundation](profiles/search-matcher-simd-foundation-1gib.jsonl),
[1 GiB SIMD](profiles/search-matcher-simd-1gib.jsonl),
[10 GiB viewer Foundation](profiles/search-matcher-simd-foundation-10gib-viewer.jsonl),
[10 GiB viewer SIMD](profiles/search-matcher-simd-10gib-viewer.jsonl), and
[mixed/adversarial](profiles/search-matcher-simd-extra.jsonl). The final
[binary provenance](profiles/search-matcher-simd-final-provenance.txt) records
source and executable hashes.
