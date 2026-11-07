# Performance reports

The Markdown reports contain the measured timings, test conditions, and
conclusions. Files in `profiles/` are supporting artifacts. Interactive HTML
flame graphs show sampled call stacks from separate profiling runs; they do
not supply the latency numbers in the tables. Raw benchmark JSONL and sampled
stack dumps are generated locally and are not committed.

| Topic | Document |
| --- | --- |
| Search baseline, SIMD steps, matcher comparisons, and flame graphs | [Search performance and profiles](search-performance.md) |
| Reproduce search fixtures and timing matrices | [Search benchmark harness](search-benchmark-harness.md) |
| Search implementation and behavior | [Document search](document-search.md) |
| Earlier editor loading and storage investigation | [Editor loading](editor-loading.md) |

The eight `search-*.html` files in `profiles/` are linked from the search
report. The `editor-load-*` artifacts and `scan-controls-ablation.json` belong
to the earlier editor investigation on `main` and are linked from its report.
