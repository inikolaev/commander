# Search sampled profile data

This appendix preserves the **top 25 inclusive frames** from each of the
eight search profiles collected on 2026-11-07. The rows were transcribed
from the original `/usr/bin/sample` summaries in commit `244c9b2`;
they are historical measurements, not new profiling runs. The paired
[performance report](search-performance.md) contains latency tables and
interprets the sampled data.

All profiles sampled the release `SearchBenchmark` process every 1 ms on
an M4 Pro MacBook Pro running macOS 27.2. Search profiles repeatedly ran
the 100 MiB case-insensitive forward `end-short` query (`Q7zE2!`); scan-only
profiles traversed the same 100 MiB fixture without matching. Both surfaces
used the default 65,536-unit chunk size. Sampling was separate
from the unprofiled latency runs. A row’s inclusive count includes its
descendants, so rows overlap and percentages do not sum to 100%. `Self`
counts samples attributed to that frame alone.

These tables preserve the most useful hot-path evidence, not the complete
call trees. For a later regression, compare the unprofiled benchmark
latency first, then collect a new profile with the same scenario and
sampling interval. A changed percentage alone does not prove a speed
change because other work can shrink or grow.

## Measured binaries

| Stage | Release binary SHA-256 |
| --- | --- |
| Baseline | `5a59cd8672f4b11f0fcef5567608f52fa9866ee9e4ad87ec18a452fd6465284b` |
| First SIMD | `934be8800069219ee0b70e3118f9e4d8ea5843b530920fdd52b7f4fea4dc80aa` |
| Inline high-bit | `c1ea648b3b4292de61279cda74928f7aecbdc41fad7735724b0e787c630f073f` |

The build used Swift 6.3.3 with `-O -whole-module-optimization` for
the current search modules and cached external dependency objects.
The [benchmark harness](search-benchmark-harness.md) describes the build
and fixture generation commands.

## Baseline viewer, case-insensitive end-short search

Sampled: 2026-11-07 10:15:33.817 +0200. Selected root: 4168 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `ViewerSearchSource.search(_:direction:fromByteOffset:exclusiveStartLimit:isCancelled:)` | 4,168 | 100.00% | 0 |
| `ViewerSearchSource.searchASCII(_:direction:anchor:exclusiveStartLimit:initial:isCancelled:)` | 4,162 | 99.86% | 1 |
| `ASCIILiteralScanner.consume(_:startingAt:requireASCII:)` | 3,006 | 72.12% | 1 |
| `ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 2,416 | 57.97% | 0 |
| `specialized Data._Representation.withUnsafeMutableBytes<A>(_:)` | 2,371 | 56.89% | 1 |
| `specialized __DataStorage.withUnsafeMutableBytes<A>(in:apply:)` | 2,369 | 56.84% | 2,368 |
| `protocol witness for FileContentSource.read(at:count:) in conformance LocalFileContentSource` | 1,104 | 26.49% | 0 |
| `LocalFileContentSource.read(at:count:)` | 1,103 | 26.46% | 1 |
| `__DataStorage.init(bytes:length:)` | 715 | 17.15% | 0 |
| `Data._Representation.append(contentsOf:)` | 587 | 14.08% | 1 |
| `specialized Data._Representation.init(_:)` | 586 | 14.06% | 0 |
| `specialized static __DataStorage.move(_:_:_:)` | 582 | 13.96% | 0 |
| `mach_msg2_internal` | 582 | 13.96% | 0 |
| `vm_copy` | 582 | 13.96% | 0 |
| `mach_msg2_trap` | 582 | 13.96% | 582 |
| `Data.range(of:options:in:)` | 569 | 13.65% | 1 |
| `Data._searchBoyerMoore(_:in:backwards:)` | 568 | 13.63% | 562 |
| `pread` | 284 | 6.81% | 284 |
| `specialized Data.init<A>(_:)` | 146 | 3.50% | 0 |
| `closure #1 in Data.init<A>(_:)` | 131 | 3.14% | 1 |
| `specialized Data.InlineSlice.init(_:)` | 129 | 3.10% | 0 |
| `_platform_memmove` | 121 | 2.90% | 121 |
| `LocalFileContentSource.metadata()` | 63 | 1.51% | 2 |
| `__bzero` | 62 | 1.49% | 62 |
| `fstat` | 59 | 1.42% | 59 |

## Baseline editor, case-insensitive end-short search

Sampled: 2026-11-07 10:16:11.823 +0200. Selected root: 4322 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `EditorSearchSnapshot.search(_:direction:fromUTF16Offset:exclusiveStartLimit:chunkSize:isCancelled:)` | 4,322 | 100.00% | 0 |
| `ASCIILiteralScanner.consume(_:startingAt:requireASCII:)` | 3,611 | 83.55% | 1 |
| `ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 2,849 | 65.92% | 1 |
| `specialized Data._Representation.withUnsafeMutableBytes<A>(_:)` | 2,796 | 64.69% | 1 |
| `specialized __DataStorage.withUnsafeMutableBytes<A>(in:apply:)` | 2,794 | 64.65% | 2,794 |
| `Data.range(of:options:in:)` | 734 | 16.98% | 1 |
| `Data._searchBoyerMoore(_:in:backwards:)` | 733 | 16.96% | 728 |
| `specialized collect #1 (_:) in TextRope.content(in:)` | 500 | 11.57% | 56 |
| `TextRope.content(in:)` | 500 | 11.57% | 0 |
| `_platform_memmove` | 326 | 7.54% | 326 |
| `_StringGuts.append(_:)` | 260 | 6.02% | 18 |
| `specialized Data.init<A>(_:)` | 202 | 4.67% | 0 |
| `specialized Data._Representation.init(_:)` | 178 | 4.12% | 0 |
| `specialized Data.InlineSlice.init(_:)` | 178 | 4.12% | 0 |
| `__DataStorage.init(bytes:length:)` | 177 | 4.10% | 7 |
| `_StringGuts.prepareForAppendInPlace(totalCount:otherUTF8Count:)` | 149 | 3.45% | 8 |
| `<deduplicated_symbol>` | 58 | 1.34% | 7 |
| `swift::RefCounts<swift::RefCountBitsT<(swift::RefCountInlinedness)1>>::doDecrementSlow<(swift::PerformDeinit)1>(swift::RefCountBitsT<(swift::RefCountInlinedness)1>, unsigned int)` | 57 | 1.32% | 0 |
| `_swift_release_dealloc` | 57 | 1.32% | 0 |
| `__DataStorage.init(length:)` | 51 | 1.18% | 0 |
| `__bzero` | 46 | 1.06% | 46 |
| `__DataStorage.length.setter` | 46 | 1.06% | 0 |
| `swift_beginAccess` | 44 | 1.02% | 40 |
| `swift_release` | 42 | 0.97% | 42 |
| `mach_absolute_time` | 42 | 0.97% | 42 |

## Baseline viewer, scan only

Sampled: 2026-11-07 10:16:51.845 +0200. Selected root: 3856 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `scanViewer(_:size:chunkSize:direction:)` | 3,856 | 100.00% | 8 |
| `LocalFileContentSource.read(at:count:)` | 3,803 | 98.63% | 0 |
| `__DataStorage.init(bytes:length:)` | 2,224 | 57.68% | 8 |
| `Data._Representation.append(contentsOf:)` | 1,959 | 50.80% | 1 |
| `specialized Data._Representation.init(_:)` | 1,957 | 50.75% | 0 |
| `specialized static __DataStorage.move(_:_:_:)` | 1,935 | 50.18% | 0 |
| `vm_copy` | 1,934 | 50.16% | 1 |
| `mach_msg2_internal` | 1,934 | 50.16% | 3 |
| `mach_msg2_trap` | 1,931 | 50.08% | 1,931 |
| `pread` | 1,093 | 28.35% | 1,093 |
| `specialized Data.init<A>(_:)` | 326 | 8.45% | 1 |
| `closure #1 in Data.init<A>(_:)` | 272 | 7.05% | 2 |
| `specialized Data.InlineSlice.init(_:)` | 270 | 7.00% | 0 |
| `_platform_memmove` | 238 | 6.17% | 238 |
| `__bzero` | 209 | 5.42% | 209 |
| `LocalFileContentSource.metadata()` | 125 | 3.24% | 0 |
| `fstat` | 120 | 3.11% | 120 |
| `swift::RefCounts<swift::RefCountBitsT<(swift::RefCountInlinedness)1>>::doDecrementSlow<(swift::PerformDeinit)1>(swift::RefCountBitsT<(swift::RefCountInlinedness)1>, unsigned int)` | 97 | 2.52% | 13 |
| `_swift_release_dealloc` | 84 | 2.18% | 1 |
| `_xzm_malloc_large_huge` | 71 | 1.84% | 4 |
| `xzm_segment_group_alloc_chunk` | 68 | 1.76% | 5 |
| `mach_absolute_time` | 66 | 1.71% | 66 |
| `xzm_segment_group_free_chunk` | 64 | 1.66% | 8 |
| `_xzm_segment_group_find_and_allocate_chunk` | 63 | 1.63% | 17 |
| `_xzm_reclaim_mark_used_locked` | 54 | 1.40% | 1 |

## Baseline editor, scan only

Sampled: 2026-11-07 10:17:11.801 +0200. Selected root: 3994 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `EditorSearchSnapshot.scanBlocks(direction:chunkSize:)` | 3,994 | 100.00% | 2 |
| `TextRope.content(in:)` | 3,120 | 78.12% | 0 |
| `specialized collect #1 (_:) in TextRope.content(in:)` | 3,107 | 77.79% | 231 |
| `_platform_memmove` | 1,910 | 47.82% | 1,910 |
| `_StringGuts.append(_:)` | 1,893 | 47.40% | 83 |
| `_StringGuts.prepareForAppendInPlace(totalCount:otherUTF8Count:)` | 1,300 | 32.55% | 35 |
| `specialized Data.init<A>(_:)` | 828 | 20.73% | 2 |
| `specialized Data._Representation.init(_:)` | 683 | 17.10% | 10 |
| `specialized Data.InlineSlice.init(_:)` | 673 | 16.85% | 1 |
| `__DataStorage.init(bytes:length:)` | 662 | 16.57% | 25 |
| `swift::RefCounts<swift::RefCountBitsT<(swift::RefCountInlinedness)1>>::doDecrementSlow<(swift::PerformDeinit)1>(swift::RefCountBitsT<(swift::RefCountInlinedness)1>, unsigned int)` | 288 | 7.21% | 19 |
| `_swift_release_dealloc` | 260 | 6.51% | 4 |
| `swift_beginAccess` | 228 | 5.71% | 194 |
| `mach_absolute_time` | 193 | 4.83% | 193 |
| `swift_release` | 191 | 4.78% | 191 |
| `_allocateStringStorage(codeUnitCapacity:precalculatedUTF16Count:)` | 180 | 4.51% | 7 |
| `_xzm_malloc_large_huge` | 163 | 4.08% | 6 |
| `swift_retain` | 162 | 4.06% | 162 |
| `xzm_segment_group_alloc_chunk` | 157 | 3.93% | 7 |
| `_xzm_segment_group_find_and_allocate_chunk` | 151 | 3.78% | 36 |
| `swift_allocObject` | 149 | 3.73% | 3 |
| `swift::swift_slowAllocTyped(unsigned long, unsigned long, unsigned long long)` | 145 | 3.63% | 6 |
| `xzm_segment_group_free_chunk` | 125 | 3.13% | 6 |
| `_xzm_reclaim_mark_used_locked` | 121 | 3.03% | 4 |
| `mach_vm_reclaim_try_cancel` | 117 | 2.93% | 22 |

## First SIMD viewer, case-insensitive end-short search

Sampled: 2026-11-07 10:28:42.512 +0200. Selected root: 4084 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `ViewerSearchSource.search(_:direction:fromByteOffset:exclusiveStartLimit:isCancelled:)` | 4,084 | 100.00% | 0 |
| `ViewerSearchSource.searchASCII(_:direction:anchor:exclusiveStartLimit:initial:isCancelled:)` | 4,067 | 99.58% | 3 |
| `ASCIILiteralScanner.consume(_:startingAt:requireASCII:)` | 2,132 | 52.20% | 2 |
| `protocol witness for FileContentSource.read(at:count:) in conformance LocalFileContentSource` | 1,843 | 45.13% | 1 |
| `LocalFileContentSource.read(at:count:)` | 1,840 | 45.05% | 1 |
| `__DataStorage.init(bytes:length:)` | 1,154 | 28.26% | 4 |
| `ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 1,071 | 26.22% | 4 |
| `Data.range(of:options:in:)` | 1,031 | 25.24% | 3 |
| `Data._searchBoyerMoore(_:in:backwards:)` | 1,022 | 25.02% | 1,011 |
| `specialized Data._Representation.init(_:)` | 1,020 | 24.98% | 0 |
| `Data._Representation.append(contentsOf:)` | 1,020 | 24.98% | 0 |
| `specialized static __DataStorage.move(_:_:_:)` | 1,010 | 24.73% | 0 |
| `vm_copy` | 1,010 | 24.73% | 3 |
| `mach_msg2_internal` | 1,007 | 24.66% | 2 |
| `mach_msg2_trap` | 1,005 | 24.61% | 1,005 |
| `specialized Data._Representation.withUnsafeMutableBytes<A>(_:)` | 991 | 24.27% | 2 |
| `specialized __DataStorage.withUnsafeMutableBytes<A>(in:apply:)` | 986 | 24.14% | 1 |
| `closure #1 in closure #2 in ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 985 | 24.12% | 654 |
| `pread` | 491 | 12.02% | 491 |
| `specialized SIMD<>.min()` | 331 | 8.10% | 331 |
| `specialized Data.init<A>(_:)` | 162 | 3.97% | 0 |
| `closure #1 in Data.init<A>(_:)` | 142 | 3.48% | 2 |
| `specialized Data.InlineSlice.init(_:)` | 138 | 3.38% | 0 |
| `LocalFileContentSource.metadata()` | 125 | 3.06% | 0 |
| `fstat` | 121 | 2.96% | 121 |

## First SIMD editor, case-insensitive end-short search

Sampled: 2026-11-07 10:28:54.961 +0200. Selected root: 4182 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `EditorSearchSnapshot.search(_:direction:fromUTF16Offset:exclusiveStartLimit:chunkSize:isCancelled:)` | 4,182 | 100.00% | 1 |
| `ASCIILiteralScanner.consume(_:startingAt:requireASCII:)` | 2,927 | 69.99% | 1 |
| `ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 1,513 | 36.18% | 7 |
| `specialized Data._Representation.withUnsafeMutableBytes<A>(_:)` | 1,429 | 34.17% | 1 |
| `specialized __DataStorage.withUnsafeMutableBytes<A>(in:apply:)` | 1,423 | 34.03% | 1 |
| `closure #1 in closure #2 in ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 1,422 | 34.00% | 940 |
| `Data._searchBoyerMoore(_:in:backwards:)` | 1,372 | 32.81% | 1,359 |
| `Data.range(of:options:in:)` | 1,372 | 32.81% | 0 |
| `TextRope.content(in:)` | 962 | 23.00% | 2 |
| `specialized collect #1 (_:) in TextRope.content(in:)` | 955 | 22.84% | 84 |
| `_platform_memmove` | 568 | 13.58% | 568 |
| `_StringGuts.append(_:)` | 536 | 12.82% | 31 |
| `specialized SIMD<>.min()` | 482 | 11.53% | 482 |
| `_StringGuts.prepareForAppendInPlace(totalCount:otherUTF8Count:)` | 334 | 7.99% | 13 |
| `specialized Data.init<A>(_:)` | 267 | 6.38% | 0 |
| `specialized Data.InlineSlice.init(_:)` | 231 | 5.52% | 1 |
| `specialized Data._Representation.init(_:)` | 231 | 5.52% | 0 |
| `__DataStorage.init(bytes:length:)` | 228 | 5.45% | 10 |
| `swift::RefCounts<swift::RefCountBitsT<(swift::RefCountInlinedness)1>>::doDecrementSlow<(swift::PerformDeinit)1>(swift::RefCountBitsT<(swift::RefCountInlinedness)1>, unsigned int)` | 115 | 2.75% | 1 |
| `_swift_release_dealloc` | 110 | 2.63% | 0 |
| `<deduplicated_symbol>` | 98 | 2.34% | 21 |
| `mach_absolute_time` | 98 | 2.34% | 98 |
| `__DataStorage.init(length:)` | 75 | 1.79% | 0 |
| `swift_beginAccess` | 73 | 1.75% | 67 |
| `__bzero` | 62 | 1.48% | 62 |

## Inline high-bit viewer, case-insensitive end-short search

Sampled: 2026-11-07 10:40:20.768 +0200. Selected root: 3330 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `ViewerSearchSource.search(_:direction:fromByteOffset:exclusiveStartLimit:isCancelled:)` | 3,330 | 100.00% | 0 |
| `ViewerSearchSource.searchASCII(_:direction:anchor:exclusiveStartLimit:initial:isCancelled:)` | 3,322 | 99.76% | 0 |
| `LocalFileContentSource.read(at:count:)` | 1,726 | 51.83% | 2 |
| `protocol witness for FileContentSource.read(at:count:) in conformance LocalFileContentSource` | 1,726 | 51.83% | 0 |
| `ASCIILiteralScanner.consume(_:startingAt:requireASCII:)` | 1,508 | 45.29% | 1 |
| `__DataStorage.init(bytes:length:)` | 1,066 | 32.01% | 5 |
| `Data.range(of:options:in:)` | 1,033 | 31.02% | 4 |
| `Data._searchBoyerMoore(_:in:backwards:)` | 1,029 | 30.90% | 1,023 |
| `Data._Representation.append(contentsOf:)` | 947 | 28.44% | 0 |
| `specialized Data._Representation.init(_:)` | 946 | 28.41% | 1 |
| `specialized static __DataStorage.move(_:_:_:)` | 928 | 27.87% | 0 |
| `mach_msg2_internal` | 928 | 27.87% | 1 |
| `vm_copy` | 928 | 27.87% | 0 |
| `mach_msg2_trap` | 927 | 27.84% | 927 |
| `pread` | 474 | 14.23% | 474 |
| `ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 441 | 13.24% | 0 |
| `specialized Data._Representation.withUnsafeMutableBytes<A>(_:)` | 359 | 10.78% | 3 |
| `closure #1 in closure #2 in ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 352 | 10.57% | 352 |
| `specialized __DataStorage.withUnsafeMutableBytes<A>(in:apply:)` | 352 | 10.57% | 0 |
| `LocalFileContentSource.metadata()` | 146 | 4.38% | 2 |
| `specialized Data.init<A>(_:)` | 142 | 4.26% | 0 |
| `fstat` | 139 | 4.17% | 139 |
| `closure #1 in Data.init<A>(_:)` | 129 | 3.87% | 1 |
| `specialized Data.InlineSlice.init(_:)` | 128 | 3.84% | 0 |
| `_platform_memmove` | 109 | 3.27% | 109 |

## Inline high-bit editor, case-insensitive end-short search

Sampled: 2026-11-07 10:40:26.132 +0200. Selected root: 3409 samples.

| Frame | Inclusive samples | Share of root | Self samples |
| --- | ---: | ---: | ---: |
| `EditorSearchSnapshot.search(_:direction:fromUTF16Offset:exclusiveStartLimit:chunkSize:isCancelled:)` | 3,409 | 100.00% | 1 |
| `ASCIILiteralScanner.consume(_:startingAt:requireASCII:)` | 2,120 | 62.19% | 2 |
| `Data.range(of:options:in:)` | 1,521 | 44.62% | 1 |
| `Data._searchBoyerMoore(_:in:backwards:)` | 1,520 | 44.59% | 1,511 |
| `TextRope.content(in:)` | 990 | 29.04% | 0 |
| `specialized collect #1 (_:) in TextRope.content(in:)` | 984 | 28.86% | 80 |
| `_platform_memmove` | 580 | 17.01% | 580 |
| `_StringGuts.append(_:)` | 563 | 16.52% | 36 |
| `ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 561 | 16.46% | 0 |
| `specialized Data._Representation.withUnsafeMutableBytes<A>(_:)` | 484 | 14.20% | 2 |
| `specialized __DataStorage.withUnsafeMutableBytes<A>(in:apply:)` | 470 | 13.79% | 1 |
| `closure #1 in closure #2 in ASCIILiteralQuery.preparedBlock(_:requireASCII:)` | 469 | 13.76% | 469 |
| `_StringGuts.prepareForAppendInPlace(totalCount:otherUTF8Count:)` | 338 | 9.91% | 14 |
| `specialized Data.init<A>(_:)` | 285 | 8.36% | 2 |
| `specialized Data._Representation.init(_:)` | 239 | 7.01% | 2 |
| `specialized Data.InlineSlice.init(_:)` | 237 | 6.95% | 0 |
| `__DataStorage.init(bytes:length:)` | 233 | 6.83% | 3 |
| `swift::RefCounts<swift::RefCountBitsT<(swift::RefCountInlinedness)1>>::doDecrementSlow<(swift::PerformDeinit)1>(swift::RefCountBitsT<(swift::RefCountInlinedness)1>, unsigned int)` | 100 | 2.93% | 7 |
| `<deduplicated_symbol>` | 97 | 2.85% | 23 |
| `_swift_release_dealloc` | 89 | 2.61% | 2 |
| `swift_release` | 81 | 2.38% | 81 |
| `__DataStorage.init(length:)` | 71 | 2.08% | 0 |
| `mach_absolute_time` | 71 | 2.08% | 71 |
| `swift_beginAccess` | 70 | 2.05% | 59 |
| `_allocateStringStorage(codeUnitCapacity:precalculatedUTF16Count:)` | 67 | 1.97% | 2 |
