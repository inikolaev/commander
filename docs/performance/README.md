# Performance reports

The Markdown reports contain the measured timings, test conditions, sampled
profile observations, and conclusions. Raw search benchmark JSONL and sampled
stack dumps are generated locally and are not committed.

| Topic | Document |
| --- | --- |
| Search baseline, SIMD steps, matcher comparisons, and profile observations | [Search performance and profiles](search-performance.md) |
| Ranked sampled frames, counts, timestamps, and binary hashes for later comparison | [Search sampled profile data](search-profile-data.md) |
| Reproduce search fixtures and timing matrices | [Search benchmark harness](search-benchmark-harness.md) |
| Search implementation and behavior | [Document search](document-search.md) |
| Earlier editor loading and storage investigation | [Editor loading](editor-loading.md) |

Search profiling observations are summarized in the report and preserved as
ranked sample data in the Markdown appendix; there are no search artifacts in
`profiles/`. The `editor-load-*` artifacts and
`scan-controls-ablation.json` belong to the earlier editor investigation on
`main` and are linked from its report.
