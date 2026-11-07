# Literal matcher experiments

The [SIMD search work](search-simd-bitmask-results.md) leaves substring
matching in Foundation's `Data.range(of:)` path. Its Boyer–Moore implementation
accounted for 30.9% of viewer and 44.6% of editor samples in the final
100 MiB case-insensitive end-short profiles. This follow-up makes the byte
matcher selectable in the benchmark while the normal viewer and editor APIs
continue to use Foundation. The selector is passed into the shared scanner;
it does not affect ASCII preparation, Unicode fallback, chunk overlap, or
source-coordinate handling.

| Matcher | Search method | Status |
| --- | --- | --- |
| Foundation | `Data.range(of:)` | Production default |
| Darwin `memmem` | libc byte substring search | Benchmark-only; slower on common multi-byte cases |
| Short SIMD | Two-byte vector filter, then `memcmp` | Benchmark-only; strong selective gains, mixed-text uncertainty |
| Swift single-pattern Aho-Corasick | Failure-link scan (KMP-equivalent), no SIMD prefilter | Benchmark-only; slower on the tested hits |

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
the editor in the Foundation run, and 19.15 and 9.90 ms in the SIMD run.
Subtracting each run's own scan median gives viewer end-short differences of
13.90 and 11.55 ms, and editor differences of 13.78 and 10.12 ms. These are
separate-run estimates, not isolated matcher costs; they include the same
case-insensitive preparation in both matchers.

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

## Experiment 3: Swift single-pattern Aho-Corasick

For the app's one-literal search contract, a one-pattern Aho-Corasick trie is
a single path. This candidate builds its failure links once per scanner and
uses the resulting KMP-equivalent byte automaton in both directions. It has
no SIMD prefilter. It runs through the same viewer/editor adapters, ASCII
preparation, chunk boundaries, and Unicode fallback as the other choices.
This is a handwritten Swift candidate, not a benchmark of the optimized
Rust library used by [Zed](https://github.com/zed-industries/zed/blob/main/crates/project/src/search.rs).
That library's builder supports [prefilters](https://docs.rs/aho-corasick/latest/aho_corasick/struct.AhoCorasickBuilder.html#method.prefilter)
and other backends absent here.

The following 100 MiB results use **one release binary** for all four
matchers. Each matrix covers 44 viewer/editor scenarios with 8 iterations;
the first iteration of each scenario is excluded. Values are medians in
milliseconds, lower is better. `CI` means case-insensitive. Scan-only rows
measure traversal without a search.

| 100 MiB case, CI | Foundation | `memmem` | SIMD | Swift AC |
| --- | ---: | ---: | ---: | ---: |
| Viewer scan-only forward | 20.00 | 19.66 | 19.50 | 19.77 |
| Viewer middle short, forward | 16.44 | 35.67 | 15.02 | 37.57 |
| Viewer end short, forward | 34.20 | 71.20 | 30.00 | 76.00 |
| Viewer end long, forward | 26.26 | 70.71 | 25.09 | 74.49 |
| Viewer absent, forward | 83.29 | 70.48 | 76.96 | 74.10 |
| Viewer begin short, reverse | 32.70 | 33.40 | 32.71 | 142.39 |
| Editor scan-only forward | 9.75 | 9.86 | 10.08 | 9.92 |
| Editor middle short, forward | 11.56 | 29.88 | 10.15 | 33.88 |
| Editor end short, forward | 23.01 | 60.29 | 20.22 | 64.90 |
| Editor end long, forward | 15.03 | 59.90 | 15.49 | 65.13 |
| Editor absent, forward | 66.41 | 60.34 | 66.54 | 63.85 |
| Editor begin short, reverse | 22.40 | 22.34 | 22.42 | 130.17 |

The extra matrix uses mixed 16 MiB text, a repeated 100 MiB file, and a
periodic 16 MiB file. It covers 176 scenarios and 1408 iteration records
across all four matchers and both surfaces/directions. Selected forward
medians in milliseconds:

| Case | Foundation | `memmem` | SIMD | Swift AC |
| --- | ---: | ---: | ---: | ---: |
| Mixed short tail hit, viewer | 10.49 | 12.84 | 10.16 | 20.32 |
| Mixed short tail hit, editor | 8.74 | 10.80 | 10.13 | 18.67 |
| Mixed short absent, viewer | 11.61 | 12.92 | 4.44 | 14.79 |
| Mixed short absent, editor | 9.50 | 11.74 | 3.16 | 19.80 |
| Mixed one-byte absent, viewer | 7.51 | 4.11 | 4.72 | 11.80 |
| Mixed one-byte absent, editor | 5.92 | 2.51 | 3.13 | 10.32 |
| Repeated near miss, viewer | 107.69 | 194.83 | 29.25 | 190.63 |
| Repeated near miss, editor | 99.15 | 186.20 | 19.82 | 181.54 |
| Periodic near miss, viewer | 9.84 | 19.56 | 9.95 | 19.48 |
| Periodic near miss, editor | 8.15 | 17.70 | 7.86 | 15.40 |

The mixed editor short tail hit was 16% slower with SIMD in this run, versus
about 2% in the earlier run above. This variation reinforces the decision to
keep it benchmark-selectable until paired repeats resolve that case.

At 1 GiB, the viewer end-short hit took 347.87 ms with Foundation and
775.48 ms with Swift AC; the editor took 251.13 and 691.82 ms. The reverse
begin-short case took 340.42 versus 1471.89 ms in the viewer and 237.28
versus 1370.38 ms in the editor. These paired 1 GiB matrices each passed 18
scenarios and 108 iteration records. A targeted 10 GiB viewer end-short run
passed four iterations per matcher and took 3.55 s with Foundation versus
7.86 s with Swift AC. We did not run the 10 GiB editor case because its
memory requirement is substantially higher.

All recorded search results were correct. The release build passed 31
`TextSearchCore` tests and 56 focused 1 MiB viewer/editor benchmark cases.
The senior advisor reviewed the candidate; the dedicated reviewer agent was
unavailable due a usage limit. The new candidate remains benchmark-only.
The measured losses are consistent with this implementation inspecting every
byte while Foundation can skip ahead; that explanation is an inference from
the algorithms and the earlier Foundation profile. The 100 MiB
absent case is an exception, but it does not offset the hit and reverse
regressions. This result does not predict the performance of Zed's Rust
`aho-corasick` library or multi-pattern searches.

Raw results: [100 MiB Foundation](profiles/search-algorithms-foundation-100mib.jsonl),
[100 MiB `memmem`](profiles/search-algorithms-memmem-100mib.jsonl),
[100 MiB SIMD](profiles/search-algorithms-simd-100mib.jsonl),
[100 MiB Swift AC](profiles/search-algorithms-aho-100mib.jsonl),
[mixed/adversarial](profiles/search-algorithms-extra.jsonl),
[1 GiB Foundation](profiles/search-algorithms-foundation-1gib.jsonl),
[1 GiB Swift AC](profiles/search-algorithms-aho-1gib.jsonl),
[10 GiB viewer Foundation](profiles/search-algorithms-foundation-10gib-viewer-end-short.jsonl),
[10 GiB viewer Swift AC](profiles/search-algorithms-aho-10gib-viewer-end-short.jsonl),
and [binary provenance](profiles/search-algorithms-provenance.txt). The binary
was built before the Aho candidate was committed, so provenance records the
parent revision plus hashes of the candidate sources and measured executable.
The benchmark, corpus generator, and profiler remain manual tools outside CI.

## Strategy-file refactor sanity check

The matcher implementations were moved into separate files behind an internal
prepared-strategy interface. The normal API still constructs Foundation.
Before and after release binaries were compared on existing small fixtures:
`/private/tmp/SearchBenchmark-pre-strategy-refactor` (SHA-256 `8fc657a7…`)
and `.build/search-benchmark-offline/SearchBenchmark` (SHA-256 `700f6c80…`).
Both used `--matcher foundation`; the first iteration of each invocation was
excluded. The 1 MiB beginning short hit used 30 iterations and four alternating
old/new invocation pairs. Median invocation medians were 24.98 → 25.71 µs
for viewer and 11.94 → 12.04 µs for editor. Individual invocation medians
overlapped, so this check does not establish a tiny-search regression. A
single eight-iteration pair for a 16 MiB mixed-text no-hit case measured
11.72 → 11.13 ms for viewer and 9.62 → 9.60 ms for editor; one pair is only
a smoke check. All checked results were correct. Full matcher matrices were
not rerun for this structural refactor.
