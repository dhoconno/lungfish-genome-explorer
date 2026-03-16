# Implementation Plan: Dual-Barcode Demultiplexing

## Overview

Add a Swift-native positional barcode scanner to complement cutadapt for asymmetric dual-barcode classification. The scanner finds the second barcode by anchoring to the ONT construct and searching the expected barcode window.

## Current Architecture

### Files involved in demultiplexing:
- `Sources/LungfishIO/Formats/FASTQ/DemultiplexingPipeline.swift` — orchestrates cutadapt
- `Sources/LungfishIO/Formats/FASTQ/PlatformAdapterContext.swift` — adapter context per platform
- `Sources/LungfishIO/Formats/FASTQ/PlatformAdapters.swift` — adapter/flank sequences
- `Sources/LungfishIO/Formats/FASTQ/PacBioBarcodeData.swift` — 384 barcode sequences
- `Sources/LungfishIO/Formats/FASTQ/ONTBarcodeData.swift` — ONT barcode sequences
- `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` — runs cutadapt binary

### Current demux flow:
1. Scout: cutadapt on first N reads → identify barcodes present
2. Full demux: cutadapt with identified barcodes → one FASTQ per barcode
3. Bundle creation: one derivative bundle per barcode

### Problem:
cutadapt assigns ONE barcode per read. For asymmetric PacBio kits (two different barcodes per read), the current pipeline assigns reads to single-barcode bins instead of barcode-PAIR bins.

## Implementation Phases

### Phase 1: `BarcodeHammingScanner` — Core Scanner (new file)

**File**: `Sources/LungfishIO/Formats/FASTQ/BarcodeHammingScanner.swift`

```swift
/// Positional Hamming-distance barcode scanner for dual-barcode reads.
///
/// Finds barcodes by anchoring to known construct elements (ONT barcode, inner flanks)
/// and searching a sliding window in the expected barcode region.
public struct BarcodeHammingScanner: Sendable {

    public struct ScanResult: Sendable {
        public let leftBarcode: String?     // 5' barcode name
        public let leftDistance: Int?        // Hamming distance
        public let rightBarcode: String?    // 3' barcode name
        public let rightDistance: Int?
        public let category: PairCategory

        public enum PairCategory: String, Sendable {
            case asymmetric    // left ≠ right (expected for most wells)
            case symmetric     // left == right
            case singleLeft    // only left barcode found
            case singleRight   // only right barcode found
            case unclassified  // neither found
        }
    }

    // Pre-computed data
    private let barcodeSequences: [String: [UInt8]]   // name → forward sequence bytes
    private let barcodeRC: [String: [UInt8]]           // name → RC sequence bytes
    private let kmerIndex: KmerIndex                   // 4-mer pre-filter
    private let kmerIndexRC: KmerIndex

    private let ontBarcode: [UInt8]        // ONT barcode for this kit
    private let ontBarcodeRC: [UInt8]
    private let innerFlank5: [UInt8]       // CAGCACCT
    private let innerFlank3: [UInt8]       // AGGTGCTG

    // Parameters
    private let maxBarcodeDistance: Int     // default 3
    private let maxAnchorDistance: Int      // default 5 for ONT BC, 1 for flank
    private let windowPadding: Int         // default 20

    public init(
        barcodeSequences: [(name: String, sequence: String)],
        ontBarcodeSequence: String,
        innerFlank: String = "CAGCACCT",
        maxBarcodeDistance: Int = 3,
        maxAnchorDistance: Int = 5,
        windowPadding: Int = 20
    ) { ... }

    /// Scan a single read for dual barcodes.
    public func scan(sequence: [UInt8]) -> ScanResult { ... }

    /// Scan a read, trying both orientations.
    public func scanBothOrientations(sequence: [UInt8]) -> ScanResult { ... }
}
```

**Key implementation details:**
- Store sequences as `[UInt8]` for SIMD-friendly Hamming distance
- `KmerIndex`: Dictionary of `(blockPosition, fourMer) → Set<barcodeIndex>` for pre-filtering
- Hamming distance: compare byte arrays, count mismatches. On Apple Silicon, use `vDSP` or manual SIMD for 16-byte barcodes (fits in one SIMD register)
- Window search: iterate positions in anchor±padding, extract 16 bytes, pre-filter with k-mer index, full Hamming on ~5-20 candidates

**Testing**: Unit tests with known barcode sequences at various distances and positions.

### Phase 2: Integrate Scanner into DemultiplexingPipeline

**File**: `Sources/LungfishIO/Formats/FASTQ/DemultiplexingPipeline.swift`

Add a new method to the pipeline:

```swift
/// Perform dual-barcode resolution after initial cutadapt classification.
///
/// For each read classified by cutadapt (single barcode), use the positional scanner
/// to find the second barcode. Returns barcode pair assignments.
func resolveDualBarcodes(
    infoFilePath: URL,
    fastqPath: URL,
    barcodeKit: BarcodeKit,
    ontBarcodeID: String
) async throws -> [String: (left: String, right: String)] { ... }
```

**Flow:**
1. Parse cutadapt info file → get first barcode + position + RC flag per read
2. Create `BarcodeHammingScanner` with the appropriate barcodes and ONT barcode
3. For each read in the FASTQ:
   a. If cutadapt found barcode near 5' (flag=0, low position) → scanner searches 3' region
   b. If cutadapt found barcode near 3' (flag=1, RC'd) → scanner searches 5' region
   c. Combine: cutadapt's barcode + scanner's barcode → pair classification
4. Return map of read_id → (left_barcode, right_barcode)

### Phase 3: Update Scout Phase

**File**: `Sources/LungfishIO/Formats/FASTQ/DemultiplexingPipeline.swift`

Modify `scoutBarcodes()` to:
1. Run cutadapt scout as before → identify present barcodes
2. Run dual-barcode scan on scout reads → identify present PAIRS
3. Report to UI: "Found N asymmetric pairs, M symmetric pairs"

This gives the user feedback about the barcode structure before full demux.

### Phase 4: Update Bundle Creation for Pairs

**File**: `Sources/LungfishIO/Formats/FASTQ/DemultiplexingPipeline.swift`

Currently: one bundle per single barcode (e.g., "bc1002")
New: one bundle per barcode PAIR (e.g., "bc1002--bc1049")

For full demux:
1. Run cutadapt to assign first barcode and generate per-barcode FASTQs
2. For each per-barcode FASTQ, run the scanner to find second barcodes
3. Sub-split each barcode bin into pair bins
4. Create derivative bundles named by pair: "bc1002--bc1049"

For single-barcode reads (scanner couldn't find second): keep in parent bin "bc1002--unresolved"

### Phase 5: CutadaptInfoFileParser (new file)

**File**: `Sources/LungfishIO/Formats/FASTQ/CutadaptInfoFileParser.swift`

```swift
/// Parser for cutadapt --info-file output.
public struct CutadaptInfoFileParser {
    public struct Record {
        public let readID: String
        public let adapterName: String?
        public let wasReverseComplemented: Bool
        public let matchStart: Int
        public let matchEnd: Int
        public let errors: Int
    }

    /// Parse info file, yielding one record per read.
    public static func parse(url: URL) throws -> [Record] { ... }

    /// Streaming parser for large files.
    public static func stream(url: URL, handler: (Record) -> Void) throws { ... }
}
```

### Phase 6: UI Updates

**Files**:
- `Sources/LungfishUI/FASTQ/FASTQOperationsPanel.swift`
- `Sources/LungfishUI/FASTQ/DemuxResultsView.swift` (or equivalent)

Updates:
- Show "Asymmetric pairs detected" in scout results
- Display pair names (bc1002--bc1049) instead of single barcode names
- Add column for pair classification (asymmetric/symmetric/single)

---

## Parameters Reference

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| cutadapt error rate | 0.20 | 3 mismatches in 16bp; balances sensitivity/specificity |
| cutadapt --no-indels | always | ONT errors are mostly substitutions at barcode scale |
| cutadapt --overlap | 12 | Minimum 12bp match for 16bp barcode |
| Scanner max barcode distance | 3 | Same as cutadapt; ~81% per-base accuracy threshold |
| Scanner max ONT anchor distance | 5 | ONT BC is 24bp; 5 mismatches = 79% accuracy |
| Scanner max flank distance | 1 | Flank is only 8bp; >1 mismatch has high false positive rate |
| Scanner window padding | 20 | ONT indels shift barcode ±5bp typically, 20bp covers 99% |
| Scanner gap requirement | ≥1 (d≥2), ≥0 (d≤1) | Prevents ambiguous assignments |

---

## Expected Performance

### Speed
- cutadapt phase: ~10s for 21k reads (already fast)
- Scanner phase: ~2-5s for 21k reads in Swift (k-mer pre-filter + compiled code)
- Total: ~15s for 21k reads

### Accuracy
- First barcode (cutadapt): 99.7% detection rate
- Second barcode (scanner): ~45% detection rate
- False positive rate: <1% (positional anchoring)
- Net: ~45% fully paired (30% asymmetric + 15% symmetric), ~47% single-barcode, ~8% unclassified
- **Biological ceiling**: Only 54.5% of reads have the 3' ONT construct (incomplete sequencing). Theoretical max paired rate is ~50%. Scanner achieves 45% — near-optimal.

### Comparison to alternatives
- cutadapt only: 0% paired (fundamental limitation)
- cutadapt two-pass unfiltered: 64.7% paired but ~50% false positives
- vsearch: Not tested, but uses global alignment — even slower than Hamming
- minimap2: Overkill for 16bp barcode matching; overhead of building index

---

## Testing Plan

1. **Unit tests** for `BarcodeHammingScanner`:
   - Known barcodes at exact positions → correct identification
   - Barcodes shifted by ±5bp (indel simulation) → still found
   - Two different barcodes at 5' and 3' → asymmetric classification
   - Same barcode at both ends → symmetric classification
   - No barcode present → unclassified
   - Random sequence → no false positive

2. **Integration tests** with real data:
   - First 20 reads from benchmark file → matches manual analysis
   - Full 21k reads → consistent with scanner v6 results

3. **Performance benchmarks**:
   - Scanner throughput: >1000 reads/second on Apple Silicon
   - Memory: O(384 × 16) barcode storage + O(1) per read

---

## Files to Create/Modify

### New files:
1. `Sources/LungfishIO/Formats/FASTQ/BarcodeHammingScanner.swift`
2. `Sources/LungfishIO/Formats/FASTQ/CutadaptInfoFileParser.swift`
3. `Tests/LungfishIOTests/BarcodeHammingScannerTests.swift`

### Modified files:
4. `Sources/LungfishIO/Formats/FASTQ/DemultiplexingPipeline.swift` — add dual-barcode resolution
5. `Sources/LungfishIO/Formats/FASTQ/PlatformAdapterContext.swift` — expose ONT barcode for scanner
6. `Sources/LungfishUI/FASTQ/FASTQOperationsPanel.swift` — show pair results

### No changes needed:
- `PacBioBarcodeData.swift` — already has all 384 barcodes
- `ONTBarcodeData.swift` — already has ONT barcode sequences
- `PlatformAdapters.swift` — already has inner flank sequences
- `NativeToolRunner.swift` — cutadapt invocation unchanged
