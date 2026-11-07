# Reproducible document search benchmark

Build a release executable with `swift build -c release --product SearchBenchmark`.
If SwiftPM cannot resolve remote dependencies but a release dependency build
already exists, the offline builder recompiles the three current search
modules and harness against those cached external modules and objects:

```sh
scripts/build-search-benchmark-offline.sh --cache-build /path/to/existing/.build
```

Pass `--modulemap /path/to/CLibArchive/module.modulemap` if the cached
`CLibArchive` artifact is elsewhere. The script prints the binary path and
writes `provenance.txt` with the source revision, compiler version, source
hashes, and binary hash. Use the same cache build, module map, and script for
baseline and post-change measurements. The cached release objects for
ArchiveCore, TextBuffer, TextRope, CFileCopy, and CLibArchive are linked as
dependencies; changes to those dependencies require refreshing the cache.

Generate files outside the repository:

```sh
python3 scripts/generate-search-fixtures.py --output-dir /private/tmp/commander-search-fixtures --sizes 100MiB 1GiB 10GiB
```

The generator writes the complete requested byte count in 1 MiB blocks. Its
working buffer is 1 MiB regardless of file size. Normal reruns validate the
existing file size and manifest metadata, then reuse both files without
rewriting them. If only the manifest is missing, the generator checks the
existing file against the deterministic corpus and writes the manifest. If
the data file is missing, it creates that size's file. `--force` explicitly
regenerates both files. Each manifest records the absolute filename, byte
count, SHA-256 digest, and expected match offsets. Verify a stored file with
`shasum -a 256` if needed; the benchmark does not hash whole files during
timed iterations.

Each fixture is ASCII `x` with LF every 128 bytes. It has six unique tokens:
short (6 bytes) and long (64 bytes) at byte offsets 32 and 48 near the
beginning, at the corresponding offsets in the 128-byte block containing the
midpoint, and in the block 256 bytes before EOF. The seventh case is absent.
The exact tokens and offsets are in the manifest. ASCII ensures that editor
UTF-16 offsets equal viewer byte offsets. The distinct tokens let a forward
search start at zero and still traverse to the intended position; a backward
search starts at the last unit by default. Use `--anchor` to measure a search
starting at another nonnegative offset.

Run each case in a separate process. Examples:

```sh
.build/release/SearchBenchmark --manifest /private/tmp/commander-search-fixtures/search-100mib.json --surface viewer --operation search --case end-short --case-sensitive --iterations 5
.build/release/SearchBenchmark --manifest /private/tmp/commander-search-fixtures/search-100mib.json --surface editor --operation search --case end-long --iterations 5
.build/release/SearchBenchmark --manifest /private/tmp/commander-search-fixtures/search-100mib.json --surface viewer --operation search --case absent --iterations 5
.build/release/SearchBenchmark --manifest /private/tmp/commander-search-fixtures/search-100mib.json --surface viewer --operation scan --iterations 5
.build/release/SearchBenchmark --manifest /private/tmp/commander-search-fixtures/search-100mib.json --surface editor --operation scan --iterations 5
```

`--direction backward` runs reverse search or reverse scan. `--query` and
`--file` allow other corpora. For an arbitrary query, `--expect-offset` plus
`--expect-length` checks a hit, while `--expect-length 0` checks an exhausted
result. Other options are `--whole-word` and `--chunk-size` (default 65,536).
`--matcher foundation|darwin-memmem|simd-short` selects the internal byte matcher
for search runs. Foundation is the default; the alternative matchers use
Foundation for reverse matching. The SIMD matcher handles short ASCII patterns
and falls back to Foundation for longer or dense patterns. The selector is
included in every JSONL record.
The fixture tokens are embedded in `x`, so whole-word searches for them are
expected to be exhausted. When combining `--whole-word` with `--case`, pass
`--expect-length 0` to override the manifest's ordinary hit expectation. A
custom `--anchor` with a manifest case also requires an explicit expected
length, since an anchor can skip that case's token.

Standard output is JSON Lines: one `setup` record, then one `iteration`
record per timed run. `elapsedNs` uses a monotonic clock. Setup includes file
open, editor text preparation, rope creation, and snapshot creation; each
search or scan time excludes setup and output serialization. Every search
record includes result, source-coordinate offset and length when found, a
stable result checksum, expected values, and `correct`. A mismatch exits
nonzero. Scan records include the number of units traversed and a cheap
per-block boundary checksum to keep traversal observable without adding a
full byte-hashing pass. Editor scan traverses the snapshot's rope with the
same chunk boundaries and UTF-8 materialization as its ASCII search path;
viewer scan uses the production `LocalFileContentSource` read path. Scan mode
includes materializing each block but no matching.

Search results on these ASCII fixtures are byte offsets for the viewer and
UTF-16 offsets for the editor. The editor holds the complete file in memory;
10 GiB editor setup may require substantial memory and can fail on a machine
that can still search the same file in the viewer. Run timing measurements
without a profiler, then use separate invocations for sampling. Warm-cache
and cold-cache runs must be labeled separately; this harness does not evict
the OS page cache.
