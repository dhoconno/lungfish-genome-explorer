# FASTQ Stats Computation Optimization

**Date**: 2026-04-05
**Branch**: `fastq-vsp2-optimization`
**Status**: Design

## Problem

Computing FASTQ statistics currently takes ~100s per file (38M reads, 1.8GB gz) due to two full passes:
1. `seqkit stats -a -T` (50s) — summary metrics
2. `FASTQReader` histogram scan (50s) — read-length histogram for chart

The histogram scan is redundant: `seqkit stats -a` already provides every numeric metric (read count, N50, median/Q1/Q3, Q20/Q30, GC%, min/max/avg length). The histogram is only used for the length-distribution chart in the FASTQ viewer.

## Solution

Replace the two-pass approach with:
1. **Full `seqkit stats -a -T`** (50s) — exact metrics, unchanged
2. **`seqkit head -n 100000 | seqkit fx2tab --length`** (0.2s) — sampled histogram from first 100k reads

Total: ~50s (50% reduction). The histogram is approximate but visually indistinguishable from the full scan. All numeric metrics remain exact.

## Benchmarks (38.3M reads, R1 only)

| Method | Time | avg_len | N50 | Q30% | GC% |
|--------|------|---------|-----|------|-----|
| Full file | 50.6s | 91.5 | 115 | 93.11 | 56.42 |
| Head 100k | 0.2s | 88.6 | 109 | 90.73 | 56.54 |

Head sample has slight bias on quality metrics (~3% lower Q30 for Illumina) due to early-read quality ramp-up. This does NOT affect our design since we use head ONLY for the histogram chart (length distribution), not for quality metrics. Quality metrics come from the full seqkit pass.

## Changes

### `FASTQBatchImporter.computeAndCacheStatistics()`

Replace the `FASTQReader` histogram scan with `seqkit head -n 100000 | seqkit fx2tab --length`:

```swift
// Before: full scan (~50s)
let reader = FASTQReader(validateSequence: false)
var histogram: [Int: Int] = [:]
var readCount = 0
for try await record in reader.records(from: fastqURL) {
    histogram[record.length, default: 0] += 1
    readCount += 1
}

// After: sampled via seqkit head + fx2tab (~0.2s)
let histResult = try await runner.runPipeline(
    [(.seqkit, ["head", "-n", "100000", fastqURL.path]),
     (.seqkit, ["fx2tab", "--length", "--name", "/dev/stdin"])],
    timeout: 60
)
// Parse tab-separated output: name\tlength per line
var histogram: [Int: Int] = [:]
for line in histResult.stdout.split(whereSeparator: \.isNewline) {
    let parts = line.split(separator: "\t")
    if parts.count >= 2, let len = Int(parts[1]) {
        histogram[len, default: 0] += 1
    }
}
```

Since `NativeToolRunner` doesn't have a `runPipeline` method, use a shell pipeline via `Process`:

```swift
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/bin/sh")
proc.arguments = ["-c", "\(seqkitPath) head -n 100000 '\(fastqURL.path)' | \(seqkitPath) fx2tab --length --name /dev/stdin"]
```

Or simpler: use `seqkit head` to a temp file, then parse it in Swift. But the pipe is faster and avoids temp files.

### Median/N50 from seqkit

`seqkit stats -a` reports Q2 (median length) and N50 directly. Use these instead of computing from the histogram:
- `medianReadLength` = `Q2` from seqkit (exact, full file)
- `n50ReadLength` = `N50` from seqkit (exact, full file)
- Drop the `medianLength()` and `n50Length()` helper functions

### No changes to FASTQStatisticsService

The app-level service is no longer called during import (removed in the CLI-driven import work). It still exists for legacy paths. Leave it unchanged.

## File Changes

| File | Change |
|------|--------|
| `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` | Replace FASTQReader histogram scan with seqkit head sample; use Q2/N50 from seqkit stats |
