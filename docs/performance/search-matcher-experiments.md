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
