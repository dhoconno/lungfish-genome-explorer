# Expert Performance Analysis: Lungfish FASTQ Processing System

*Date: 2026-03-14*
*Scope: Virtual derivative system, batch processing, reference management, materialization pipeline, UI responsiveness*

## Critical Findings Summary

| Priority | Issue | Impact | Location |
|----------|-------|--------|----------|
| P0 | GzipInputStream loads entire decompressed file into RAM | Cannot process .fastq.gz files larger than available RAM | `GzipSupport.swift` |
| P0 | extractTrimPositions reads trimmed FASTQ twice into memory | 2x RAM of trimmed file consumed for dictionaries | `FASTQDerivativeService.swift` |
| P1 | FASTQWriter does per-record String->Data->syscall | One write(2) syscall per FASTQ record | `FASTQWriter.swift` |
| P1 | createDerivative always materializes + re-computes stats | Redundant triple-pass for virtual chain operations | `FASTQDerivativeService.swift` |
| P1 | Initial FASTQ load does two full-file passes | seqkit stats + FASTQReader histogram in series | `MainSplitViewController.swift` |
| P2 | createBatchDerivative processes sequentially | Does not use TaskGroup despite BatchProcessingEngine doing so | `FASTQDerivativeService.swift` |
| P2 | FASTQTrimPositionFile.load reads entire TSV as String | Memory spike for files with millions of trim records | `FASTQDerivatives.swift` |

---

## 1. Virtual vs Materialized Tradeoffs

### Current Architecture

The system has three payload types that determine I/O cost:

- **`.subset` (virtual)**: Stores only a `read-ids.txt` file (one ID per line). Materialization requires streaming the root FASTQ and filtering by ID set. Memory cost is O(|selected IDs|) for the hash set.
- **`.trim` (virtual)**: Stores a `trim-positions.tsv` file (read_id, mate, start, end). Materialization requires streaming the root FASTQ and applying substring extraction. Memory cost is O(|trim records|).
- **`.full` (materialized)**: Stores the complete transformed FASTQ. No derivation cost at read time, but disk cost equals the full output size.

### When to Materialize vs Keep Virtual

**Keep virtual when:**
- The derivative is accessed infrequently (browse-only in sidebar)
- The read ID list is small relative to the root file (<10% of reads)
- Disk space is constrained (common with genomic workflows)
- The operation is idempotent and cheap to re-derive (subsample, length filter)

**Materialize when:**
- The derivative is input to a chain of further operations (each link would otherwise re-materialize from root)
- The derivative represents >50% of root reads (scanning cost approaches re-reading anyway)
- The derivative will be exported or used by external tools
- The operation is expensive and non-deterministic (adapter trim with auto-detect)

### Quantitative Decision Framework

For a root FASTQ of size `R` bytes, a virtual subset selecting `p` fraction of reads:

- **Virtual access cost**: O(R) per access (must scan entire root to extract matching IDs)
- **Materialized access cost**: O(p * R) per access (direct read of smaller file)
- **Virtual storage cost**: O(n * 30 bytes) for n read IDs (negligible)
- **Materialized storage cost**: O(p * R) bytes on disk

**Break-even rule**: If a virtual derivative will be accessed more than `1/(1-p)` times before the next edit, materialization saves total I/O. For p=0.1 (10% subsample), break-even is ~1.1 accesses -- meaning almost any reuse justifies materialization. For p=0.9 (90% filter), break-even is 10 accesses.

### Recommended Optimization: Lazy Materialization Cache

Introduce a file-system-backed materialization cache keyed by bundle URL + content hash:

```
~/Library/Caches/com.lungfish.browser/materialized/
  {sha256-of-bundle-manifest}.fastq
```

**Policy**: After materializing a virtual derivative, store the result in the cache with an LRU eviction policy (default 50 GB cap, user-configurable). On next access, check cache before re-deriving.

### Recommended Optimization: Composed Virtual Operations

For subset-only chains (e.g., subsample -> length filter -> deduplicate), compose read ID lists by intersection rather than materializing intermediate files. The final materialization scans root once with the intersected ID set.

For trim chains, compose trim positions algebraically (current `FASTQTrimPositionFile.compose` already does this for parent-child pairs -- extend to full chains).

---

## 2. Batch Processing Optimization

### Optimal Concurrency by Operation Type

**CPU-bound operations** (trimming, deduplication, error correction):
- External tools typically use multiple threads internally
- Optimal concurrency: `ProcessInfo.processInfo.processorCount / toolThreadCount`
- For bbduk with default 2 threads on an 8-core Mac: concurrency = 4
- For fastp with default 4 threads: concurrency = 2

**I/O-bound operations** (subsample, length filter, search):
- SSD sequential read throughput is shared across all concurrent readers
- Optimal concurrency: 2-3 (more causes I/O contention on NVMe)

**Mixed operations** (contaminant filter, adapter auto-detect):
- Require both disk read and CPU-intensive kmer matching
- Optimal concurrency: `processorCount / 2`

### Recommended: Adaptive Concurrency

```swift
private func optimalConcurrency(for request: FASTQDerivativeRequest) -> Int {
    let cpuCount = ProcessInfo.processInfo.processorCount
    switch request {
    case .subsampleProportion, .subsampleCount, .lengthFilter, .searchText, .searchMotif:
        return min(3, cpuCount)  // I/O bound
    case .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval:
        return max(1, cpuCount / 4)  // CPU bound, tools use 2-4 threads each
    case .deduplicate, .errorCorrection:
        return max(1, cpuCount / 4)  // CPU + memory intensive
    case .contaminantFilter:
        return max(1, cpuCount / 3)  // Mixed
    default:
        return max(1, cpuCount / 4)
    }
}
```

### Pipeline Without Intermediate Files

**Recommended hybrid approach**: Use Unix pipes for pairs of compatible operations where the output of tool A is stdin of tool B. Fall back to temporary files when:
- The operation is a native Swift operation (not an external tool)
- Progress reporting requires knowing intermediate read counts
- The operation is non-streaming (e.g., deduplication by sequence requires seeing all reads)

### Memory Pressure Monitoring

When processing 4 barcodes concurrently with bbduk:
- bbduk kmer lookup table: ~1 GB per reference database
- Input/output buffers: ~200 MB per process
- Java heap (bbtools): ~1 GB per process
- Total: ~5 GB for 4 concurrent bbduk processes

**Recommended**: Monitor `os_proc_available_memory()` before launching new concurrent tasks. If available memory drops below 2 GB, reduce concurrency to 1.

---

## 3. Reference Sequence Management

### Recommended: Cached Reference Index

```swift
actor ReferenceSequenceCache {
    private var entries: [(url: URL, manifest: ReferenceSequenceManifest)]?
    private var lastModDate: Date?

    func listReferences(in projectURL: URL) -> [(url: URL, manifest: ReferenceSequenceManifest)] {
        let folderURL = projectURL.appendingPathComponent("Reference Sequences")
        let modDate = folderModificationDate(folderURL)
        if let entries, lastModDate == modDate {
            return entries
        }
        let fresh = ReferenceSequenceFolder.listReferences(in: projectURL)
        entries = fresh
        lastModDate = modDate
        return fresh
    }
}
```

Use the folder's modification date as a cache key. Persist a `reference-index.json` in the Reference Sequences folder for fast lookup by name or content hash.

---

## 4. Materialization Pipeline

### P0: GzipInputStream Full-File Load

**Problem**: `GzipInputStream.lines()` calls `decompressWithSystemGzip()` which reads the entire gzip file into `Data` then converts to `String`. For a 30 GB gzipped FASTQ (100 GB uncompressed), this attempts to allocate ~130 GB of RAM.

**Fix**: Stream from the gzip subprocess pipe in 1 MB chunks, yielding lines as they become available. Memory usage drops from O(file size) to O(1 MB buffer).

### P0: extractTrimPositions Double-Read

**Problem**: Reads the trimmed FASTQ file twice, building two separate dictionaries holding every record in memory simultaneously. For 10 million reads at ~500 bytes each, this consumes ~10 GB of RAM.

**Fix**: Merge both passes into a single pass, building only `trimmedByBaseID` (the one actually used in matching).

### P1: FASTQWriter Unbuffered Writes

**Problem**: Each `write(_ record:)` call issues a `write(2)` syscall. For 10 million records, that's 10 million syscalls (~10 seconds pure overhead).

**Fix**: Add 256 KB write buffer. Reduces syscalls by ~1000x. Estimated 3-5x faster write throughput.

### P1: Redundant Statistics Computation

**Problem**: After running the transformation tool, `createDerivative` always computes full statistics in a separate pass. Combined with other passes, this means 3 full reads of the trimmed file.

**Fix**: Piggyback `FASTQStatisticsCollector` onto the materialization/extraction pass. Single-pass design halves I/O.

### Streaming Materialization Architecture

```
[Root FASTQ Reader] -> [ID/Trim Filter] -> [Buffered Writer] -> [Output File]
                            |
                     [Stats Collector] (piggyback)
```

All three concerns (filtering, writing, statistics) happen in a single streaming pass.

### Progress Reporting

Report progress as `(readsProcessed, totalReadsEstimate)` using root bundle's cached read count. Update every 10,000 reads for smooth progress bar without excessive callback overhead.

---

## 5. UI Responsiveness

### Sidebar Lazy Loading for Large Projects

For demux groups with 96+ barcodes:
1. On initial project open, scan only top-level items (no metadata parsing)
2. When a group is expanded, load child items lazily
3. Background-load metadata for visible items, updating via `outlineView.reloadItem(_:reloadChildren:false)`

### Cached vs Live Statistics

**Rule**: Always show cached statistics immediately. Show a "computing" indicator only when no cache exists.

**Staleness detection**: Add `rootFileModificationDate` field to manifest. Show staleness indicator if root file has been modified since derivative creation.

### Operation Panel Optimization

Pre-build parameter views for each operation type and swap visibility rather than recreating views on each selection change.

---

## 6. Implementation Priority

### Phase 1: Critical Memory Safety (P0)
1. Fix `GzipInputStream` to stream decompression
2. Fix `extractTrimPositions` single-pass

### Phase 2: Throughput Improvements (P1)
3. Add FASTQWriter buffering (3-5x write speedup)
4. Merge statistics into materialization pass
5. Single-pass initial FASTQ load

### Phase 3: Architecture Improvements (P2)
6. Materialization cache (LRU file cache)
7. Adaptive batch concurrency
8. Streaming trim position file parsing
9. Sidebar lazy loading

### Phase 4: Advanced Optimizations
10. Unix pipe chaining for compatible tools
11. Reference sequence folder caching
12. Composed virtual operations (ID set intersection)

---

## 7. Scalability Testing Recommendations

| Scenario | File Size | Read Count | Expected Behavior |
|----------|-----------|------------|-------------------|
| Small FASTQ | 100 MB | 200K reads | All operations < 30 seconds |
| Medium FASTQ | 5 GB | 10M reads | Subset operations < 2 minutes, trim < 5 minutes |
| Large FASTQ | 50 GB | 100M reads | Subset < 15 minutes, trim < 30 minutes |
| XL FASTQ.gz | 30 GB compressed | 200M reads | Must not OOM (currently will) |
| Batch 96 barcodes | 96 x 500 MB | 96 x 1M reads | Complete in < 2 hours with 4 concurrency |

### Memory Profiling Targets (post-optimization)
- Peak memory during materialization: < 500 MB regardless of file size
- Peak memory during statistics computation: < 200 MB regardless of file size
- Peak memory during batch processing (4 concurrent): < 8 GB total
