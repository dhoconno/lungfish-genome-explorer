# Demultiplexing Enhancement Plan

## Overview

Redesign the demultiplexing system to support multi-platform adapter+barcode
trimming in a single pass, multi-step demultiplexing, interactive barcode
scouting, and generalized asymmetric barcode handling. The core architectural
change: construct full adapter+barcode+flank sequences per platform so cutadapt
matches the entire construct in one pass, eliminating false matches.

---

## Part 1: Platform Adapter Architecture

### 1.1 New `SequencingPlatform` Enum

Replace the free-form `vendor: String` with a first-class enum. Store on FASTQ
bundle metadata so all downstream processing knows what to expect.

```swift
// Sources/LungfishIO/Formats/FASTQ/SequencingPlatform.swift

public enum SequencingPlatform: String, Codable, Sendable, CaseIterable {
    case illumina       // TruSeq, Nextera, NovaSeq, etc.
    case oxfordNanopore  // MinION, PromethION, etc.
    case pacbio          // Sequel, Revio (HiFi/CCS reads)
    case element         // AVITI
    case ultima          // UG100
    case mgi             // DNBSEQ (MGI/BGI)
    case unknown

    /// Human-readable display name
    public var displayName: String { ... }

    /// Whether reads can appear in either orientation
    public var readsCanBeReverseComplemented: Bool {
        switch self {
        case .oxfordNanopore, .pacbio: return true
        default: return false
        }
    }

    /// Whether this platform's indexes are in separate reads (already demuxed)
    public var indexesInSeparateReads: Bool {
        switch self {
        case .illumina, .element, .ultima, .mgi: return true
        case .oxfordNanopore, .pacbio: return false
        default: return false
        }
    }

    /// Whether poly-G trimming may be needed (two-color SBS platforms)
    public var mayNeedPolyGTrimming: Bool {
        switch self {
        case .illumina, .element: return true
        default: return false
        }
    }

    /// Recommended cutadapt error rate for this platform
    public var recommendedErrorRate: Double {
        switch self {
        case .oxfordNanopore: return 0.20
        case .pacbio:         return 0.10
        default:              return 0.10
        }
    }
}
```

### 1.2 Embedded Platform Adapter Sequences

All constant/universal adapter sequences, embedded in the app. Users never need
to know these.

```swift
// Sources/LungfishIO/Formats/FASTQ/PlatformAdapters.swift

public enum PlatformAdapters {

    // MARK: - ONT

    /// Y-adapter top strand (Native Barcoding kits: NBD104, NBD114, etc.)
    public static let ontYAdapterTop = "AATGTACTTCGTTCAGTTACGTATTGCT"
    /// Y-adapter bottom strand (reverse complement of top)
    public static let ontYAdapterBottom = "AGCAATACGTAACTGAACGAAGT"
    /// Native barcode 5' flank (constant across all native barcodes)
    public static let ontNativeBarcodeFlank5 = "CAGCACCT"
    /// Native barcode 3' flank (reverse complement of 5' flank)
    public static let ontNativeBarcodeFlank3 = "AGGTGCTG"
    /// Rapid adapter (RAP-T, used in RBK, RAD, RPB kits)
    public static let ontRapidAdapter =
        "GGCGTCTGCTTGGGTGTTTAACCTTTTTTTTTTAATGTACTTCGTTCAGTTACGTATTGCT"
    /// Transposase mosaic end (rapid barcoding)
    public static let ontTransposaseME = "AGATGTGTATAAGAGACAG"
    public static let ontTransposaseMErc = "CTGTCTCTTATACACATCT"

    // MARK: - Illumina

    /// Universal adapter prefix (matches both TruSeq R1 and R2)
    public static let illuminaUniversal = "AGATCGGAAGAG"
    /// TruSeq Read 1 adapter (read-through contamination in R1)
    public static let truseqR1 = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"
    /// TruSeq Read 2 adapter (read-through contamination in R2)
    public static let truseqR2 = "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT"
    /// Nextera/DNA Prep Read 1
    public static let nexteraR1 = "CTGTCTCTTATACACATCTCCGAGCCCACGAGAC"
    /// Nextera/DNA Prep Read 2
    public static let nexteraR2 = "CTGTCTCTTATACACATCTGACGCTGCCGACGA"
    /// Small RNA 3' adapter
    public static let smallRNA3 = "TGGAATTCTCGGGTGCCAAGG"
    /// Small RNA 5' adapter
    public static let smallRNA5 = "GTTCAGAGTTCTACAGTCCGACGATC"

    // MARK: - PacBio

    /// SMRTbell adapter v3 (current, Revio/Sequel IIe)
    public static let smrtbellV3 = "AAAAAAAAAAAAAAAAAATTAACGGAGGAGGAGGA"
    /// SMRTbell adapter v2
    public static let smrtbellV2 = "AAGTCACAGCGGAACGGCGA"
    /// SMRTbell adapter v1 (legacy)
    public static let smrtbellV1 =
        "ATCTCTCTCTTTTCCTCCTCCTCCGTTGTTGTTGTTGAGAGAGAT"

    // MARK: - Element (AVITI)
    // Read-through adapters are TruSeq-identical by design.
    // Use truseqR1 / truseqR2.

    // MARK: - Ultima Genomics
    // Read-through adapters are TruSeq-identical by design.
    // Use truseqR1 / truseqR2.

    // MARK: - MGI / DNBSEQ

    /// MGI Read 1 adapter
    public static let mgiR1 = "AAGTCGGAGGCCAAGCGGTCTTAGGAAGACAA"
    /// MGI Read 2 adapter
    public static let mgiR2 = "AAGTCGGATCGTAGCCATGTCGTTCTGTGAGCCAAGGAGTTG"
}
```

### 1.3 Platform-Aware Adapter Context Protocol

Replace `IlluminaAdapterContext` with a protocol that constructs the full
adapter+barcode+flank sequence per platform.

```swift
// Sources/LungfishIO/Formats/FASTQ/PlatformAdapterContext.swift

/// Constructs the full cutadapt adapter specification for a barcode,
/// including platform-specific flanking and adapter sequences.
public protocol PlatformAdapterContext: Sendable {
    /// Build the 5' adapter spec for cutadapt (-g flag)
    func fivePrimeSpec(barcodeSequence: String) -> String
    /// Build the 3' adapter spec for cutadapt (-a flag)
    func threePrimeSpec(barcodeSequence: String) -> String
    /// Build linked adapter spec (5'...3') for cutadapt
    func linkedSpec(barcodeSequence: String) -> String
}
```

**Implementations:**

```swift
/// ONT Native Barcoding: Y-adapter + barcode + flank ... flank + barcode_rc + Y-adapter_rc
public struct ONTNativeAdapterContext: PlatformAdapterContext {
    public func fivePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontYAdapterTop + barcodeSequence
            + PlatformAdapters.ontNativeBarcodeFlank5
    }
    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontNativeBarcodeFlank3
            + reverseComplement(barcodeSequence)
            + PlatformAdapters.ontYAdapterBottom
    }
    public func linkedSpec(barcodeSequence: String) -> String {
        fivePrimeSpec(barcodeSequence: barcodeSequence)
            + "..." + threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

/// ONT Rapid Barcoding: Rapid adapter + barcode + ME ... ME_rc + barcode_rc
public struct ONTRapidAdapterContext: PlatformAdapterContext {
    public func fivePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontRapidAdapter + barcodeSequence
            + PlatformAdapters.ontTransposaseME
    }
    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.ontTransposaseMErc
            + reverseComplement(barcodeSequence)
    }
    public func linkedSpec(barcodeSequence: String) -> String {
        fivePrimeSpec(barcodeSequence: barcodeSequence)
            + "..." + threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

/// PacBio HiFi: barcode ... barcode_rc (no flanking adapters in CCS reads)
public struct PacBioAdapterContext: PlatformAdapterContext {
    public func fivePrimeSpec(barcodeSequence: String) -> String {
        barcodeSequence
    }
    public func threePrimeSpec(barcodeSequence: String) -> String {
        reverseComplement(barcodeSequence)
    }
    public func linkedSpec(barcodeSequence: String) -> String {
        barcodeSequence + "..." + reverseComplement(barcodeSequence)
    }
}

/// Illumina: read-through adapter trimming only (no barcode in construct)
/// Used for post-demux adapter removal.
public struct IlluminaTruSeqContext: PlatformAdapterContext {
    public func fivePrimeSpec(barcodeSequence: String) -> String { "" }
    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.truseqR1  // R1 direction; caller swaps for R2
    }
    public func linkedSpec(barcodeSequence: String) -> String {
        threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

/// MGI/DNBSEQ: distinct adapter sequences from Illumina
/// Demux is handled by zebracallV2; app does adapter read-through trimming only.
public struct MGIAdapterContext: PlatformAdapterContext {
    public func fivePrimeSpec(barcodeSequence: String) -> String { "" }
    public func threePrimeSpec(barcodeSequence: String) -> String {
        PlatformAdapters.mgiR1  // R1 direction; caller swaps to mgiR2 for R2
    }
    public func linkedSpec(barcodeSequence: String) -> String {
        threePrimeSpec(barcodeSequence: barcodeSequence)
    }
}

/// No flanking context (bare barcode sequences for custom kits)
public struct BareAdapterContext: PlatformAdapterContext {
    public func fivePrimeSpec(barcodeSequence: String) -> String {
        barcodeSequence
    }
    public func threePrimeSpec(barcodeSequence: String) -> String {
        barcodeSequence
    }
    public func linkedSpec(barcodeSequence: String) -> String {
        barcodeSequence + "..." + reverseComplement(barcodeSequence)
    }
}
```

**Factory function on SequencingPlatform:**

```swift
extension SequencingPlatform {
    /// Returns the appropriate adapter context for a kit on this platform.
    public func adapterContext(kitType: BarcodeKitType) -> any PlatformAdapterContext {
        switch self {
        case .oxfordNanopore:
            switch kitType {
            case .nativeBarcoding: return ONTNativeAdapterContext()
            case .rapidBarcoding:  return ONTRapidAdapterContext()
            default:               return ONTNativeAdapterContext()
            }
        case .pacbio:    return PacBioAdapterContext()
        case .illumina:  return IlluminaTruSeqContext()
        case .element:   return IlluminaTruSeqContext()
        case .ultima:    return IlluminaTruSeqContext()
        case .mgi:       return MGIAdapterContext()
        default:         return BareAdapterContext()
        }
    }
}
```

### 1.4 Kit Type Classification

```swift
public enum BarcodeKitType: String, Codable, Sendable {
    case nativeBarcoding    // ONT SQK-NBD*
    case rapidBarcoding     // ONT SQK-RBK*
    case pcrBarcoding       // ONT SQK-PCB*
    case sixteenS           // ONT 16S kits
    case truseq             // Illumina TruSeq
    case nextera            // Illumina Nextera
    case pacbioStandard     // PacBio barcoded adapters
    case custom
}
```

Add `kitType: BarcodeKitType` to `IlluminaBarcodeDefinition` (or its renamed
successor). Infer from existing kit IDs during migration.

---

## Part 2: Rename Generic Types

### 2.1 Rename `IlluminaBarcode` -> `BarcodeEntry`

```swift
public struct BarcodeEntry: Codable, Sendable, Equatable {
    public let id: String
    /// Primary barcode sequence (Illumina i7, ONT barcode, PacBio barcode)
    public let sequence: String
    /// Secondary sequence (Illumina i5, PacBio asymmetric 3' barcode)
    public let secondarySequence: String?
    /// User-assigned sample name
    public var sampleName: String?
}

// Backward compatibility
public typealias IlluminaBarcode = BarcodeEntry
extension BarcodeEntry {
    public var i7Sequence: String { sequence }
    public var i5Sequence: String? { secondarySequence }
}
```

### 2.2 Rename `IlluminaBarcodeDefinition` -> `BarcodeKitDefinition`

```swift
public struct BarcodeKitDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let vendor: String              // Keep for display; prefer platform
    public let platform: SequencingPlatform
    public let kitType: BarcodeKitType
    public let isDualIndexed: Bool
    public let pairingMode: BarcodePairingMode
    public let barcodes: [BarcodeEntry]
}

public typealias IlluminaBarcodeDefinition = BarcodeKitDefinition
```

### 2.3 Store `SequencingPlatform` on FASTQ Metadata

Add to `PersistedFASTQMetadata`:

```swift
public var sequencingPlatform: SequencingPlatform?
```

Auto-detect from:
- ONT header fields (`runid=`, `ch=`, `flow_cell_id=`) -> `.oxfordNanopore`
- PacBio header fields (`zmw/`, `ccs`) -> `.pacbio`
- User selection in import dialog for ambiguous cases

---

## Part 3: Generalized Asymmetric Barcode Handling

### 3.1 `BarcodeSymmetryMode` Enum

```swift
public enum BarcodeSymmetryMode: String, Codable, Sendable {
    /// Same barcode on both ends (ONT native, PacBio symmetric)
    case symmetric
    /// Different barcodes on each end (PacBio asymmetric, custom)
    case asymmetric
    /// Barcode on one end only (ONT rapid, some Illumina)
    case singleEnd
}
```

### 3.2 Updated `DemultiplexConfig`

```swift
public struct DemultiplexConfig: Sendable {
    public let inputURL: URL
    public let barcodeKit: BarcodeKitDefinition
    public let outputDirectory: URL
    public let barcodeLocation: BarcodeLocation
    public let symmetryMode: BarcodeSymmetryMode  // NEW
    public let errorRate: Double
    public let minimumOverlap: Int
    public let trimBarcodes: Bool
    public let searchReverseComplement: Bool       // NEW (default from platform)
    public let adapterContext: (any PlatformAdapterContext)?  // NEW
    public let unassignedDisposition: UnassignedDisposition
    public let threads: Int
    public let sampleAssignments: [FASTQSampleBarcodeAssignment]
}
```

### 3.3 Independent-End Strategy for Asymmetric Barcodes

When `symmetryMode == .asymmetric`:

1. Generate separate adapter FASTA entries for 5' and 3' barcodes
   (N + M entries, not N x M)
2. Run cutadapt with `--pair-adapters` or two separate 5'/3' adapter sets
3. Parse output to determine which 5' barcode and which 3' barcode matched
4. Combine into a composite identity: `"bc1003--bc1016"`
5. Map composite identity to sample name via `sampleAssignments`

When `symmetryMode == .symmetric`:

1. Generate linked adapters where 5' and 3' use the same barcode sequence
   (with appropriate adapter context wrapping)
2. Standard cutadapt demux

When `symmetryMode == .singleEnd`:

1. Generate only 5' (or 3') adapters based on `barcodeLocation`
2. Standard cutadapt demux

### 3.4 Orientation Handling for Long Reads

ONT and PacBio reads can be in either orientation. The adapter context handles
this transparently:

- cutadapt `--revcomp` flag: searches both forward and reverse complement of
  each read. When a match is found on the reverse complement, cutadapt outputs
  the read in the canonical (forward) orientation.
- Default to `searchReverseComplement = true` when
  `platform.readsCanBeReverseComplemented`
- No data model changes needed; this is a cutadapt flag controlled by config

---

## Part 4: Multi-Step Demultiplexing

### 4.1 Data Model

```swift
/// A single step in a multi-step demultiplexing plan.
public struct DemultiplexStep: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Human label: "Outer (ONT)", "Inner (PacBio)", etc.
    public var label: String
    /// Which barcode kit to use
    public var barcodeKitID: String
    /// Override barcode location for this step
    public var barcodeLocation: BarcodeLocation
    /// Override symmetry mode for this step
    public var symmetryMode: BarcodeSymmetryMode
    /// Override error rate for this step
    public var errorRate: Double
    /// Per-step sample assignments (for asymmetric kits)
    public var sampleAssignments: [FASTQSampleBarcodeAssignment]
    /// Zero-indexed ordinal (step 0 runs first on raw input)
    public var ordinal: Int
}

/// Complete multi-step demultiplexing plan.
public struct DemultiplexPlan: Codable, Sendable, Equatable {
    /// Ordered steps. Step 0 is outermost.
    public var steps: [DemultiplexStep]
    /// Map composite barcode paths to user-assigned sample names.
    /// Key: "BC01/bc1003--bc1016", Value: "Patient-042"
    public var compositeSampleNames: [String: String]
}
```

### 4.2 Execution Flow

```
Step 0: Run cutadapt on raw input -> N outer bins
Step 1: For each outer bin, run cutadapt -> M inner bins per outer bin
Step 2: (rare) For each inner bin, run cutadapt -> ...

Output directory structure:
  output/
    BC01/
      bc1003--bc1016.lungfishfastq/
      bc1008--bc1008.lungfishfastq/
    BC02/
      bc1003--bc1016.lungfishfastq/
    unassigned/
```

Pipeline method:

```swift
public func runMultiStep(
    plan: DemultiplexPlan,
    inputURL: URL,
    outputDirectory: URL,
    progress: @escaping @Sendable (Double, String) -> Void
) async throws -> MultiStepDemultiplexResult
```

- Step 0 gets ~50% of progress bar, step 1 gets ~50%
- Step 1 runs can be parallelized across outer bins (up to `maxConcurrentBarcodes`)
- Each step uses `buildConfig(from: DemultiplexStep)` to create a single-step
  `DemultiplexConfig`, reusing the existing pipeline

### 4.3 Result Model

```swift
public struct MultiStepDemultiplexResult: Sendable {
    /// Per-step results
    public let stepResults: [StepResult]
    /// Final output bundles (leaf-level)
    public let outputBundleURLs: [URL]
    /// Composite manifest combining all steps
    public let manifest: DemultiplexManifest
    public let wallClockSeconds: Double

    public struct StepResult: Sendable {
        public let step: DemultiplexStep
        public let perBinResults: [DemultiplexResult]
    }
}
```

---

## Part 5: Barcode Scouting

### 5.1 Data Model

```swift
/// Result of scanning a subset of reads to detect barcodes.
public struct BarcodeScoutResult: Codable, Sendable {
    public let readsScanned: Int
    public var detections: [BarcodeDetection]
    public let unassignedCount: Int
    public let scoutedKitIDs: [String]
    public let elapsedSeconds: Double
}

public struct BarcodeDetection: Codable, Sendable, Identifiable {
    public let id: UUID
    public let barcodeID: String
    public let kitID: String
    public let hitCount: Int
    public var hitPercentage: Double
    public let matchedEnds: MatchedEnds
    public let meanEditDistance: Double?
    /// User disposition: accept, reject, or undecided
    public var disposition: DetectionDisposition
    /// User-assigned sample name
    public var sampleName: String?
}

public enum DetectionDisposition: String, Codable, Sendable {
    case accepted, rejected, undecided
}

public enum MatchedEnds: String, Codable, Sendable {
    case fivePrimeOnly, threePrimeOnly, bothEnds, unknown
}
```

### 5.2 Scout Pipeline

```swift
public func scout(
    inputURL: URL,
    kitIDs: [String],
    readLimit: Int = 10_000,
    progress: @escaping @Sendable (Double, String) -> Void
) async throws -> BarcodeScoutResult
```

Implementation:
1. Extract first `readLimit` reads to temp file (seqkit head or zcat | head)
2. Run cutadapt with `--json` against all barcodes in selected kit(s)
3. Parse JSON report for per-adapter hit counts
4. Auto-disposition: accept if hits > 10, reject if hits < 3, undecided otherwise
5. Sort by hit count descending

### 5.3 Scout Results UI (Modal Sheet)

**Header bar:**
```
Scanned 10,000 of 1,247,832 reads (0.8%) in 3.2s
12 barcodes detected | 87.3% assigned | 12.7% unassigned
Kit: ONT Native Barcoding V14 (SQK-NBD114-96)
```

**Main table (NSTableView):**

| Status | Barcode | Hits | % | End | Edit Dist | Sample Name |
|--------|---------|------|---|-----|-----------|-------------|
| [checkmark] | BC01 | 1,247 | 12.5% | Both | 0.3 | [editable] |
| [checkmark] | BC02 | 1,189 | 11.9% | Both | 0.4 | [editable] |
| [x] | BC47 | 3 | 0.03% | 5' only | 2.1 | |

- **Status column**: tri-state toggle (accepted/rejected/undecided)
- **Sample Name column**: inline editable text field
- Rows sorted by hit count descending; low-hit rows have warning styling
- High edit distance (>2.0) gets a warning icon

**Bottom action bar:**

- Left: `[+ Add Barcode]` -- popover to pick undetected barcodes from kit
- Center: Threshold controls
  - "Auto-accept barcodes with > [___] hits"
  - "Auto-reject barcodes with < [___] hits"
  - `[Apply Thresholds]`
- Right: `[Cancel]` `[Proceed with Accepted Barcodes]`

**Clicking "Proceed":**
1. Filter to accepted detections
2. Build a pruned kit containing only accepted barcodes
3. Create `DemultiplexConfig` from pruned kit + user sample names
4. Run full demultiplex

### 5.4 Persistence

Save `BarcodeScoutResult` as `scout-result.json` in the `.lungfishfastq` bundle.
Users can re-open the scout sheet without re-scanning.

### 5.5 Multi-Step Scouting

For multi-step demux plans:
- "Scout Step 1" button scouts raw input for outer barcodes
- After step 0 demux, "Scout Step 2" button scouts a representative outer bin
  for inner barcodes
- Each step has its own `BarcodeScoutResult`

---

## Part 6: UI Changes

### 6.1 Bottom Drawer Tab Restructure

Current tabs: **Samples** | **Barcode Sets**

New tabs: **Samples** | **Demux Setup** | **Barcode Kits**

#### Demux Setup Tab

This is the primary demux configuration interface. Two sections:

**Top: Step list (compact NSTableView, 3-4 rows max)**

| Step | Kit | Barcodes | Symmetry |
|------|-----|----------|----------|
| 1 - Outer | ONT Native 24 (NBD114) | 24 | Symmetric |
| 2 - Inner | PacBio Sequel 16 v3 | 16 | Asymmetric |

Buttons: `[+ Add Step]` `[- Remove]` `[Move Up]` `[Move Down]`

**Bottom: Detail panel for selected step**

- Kit popup (all registered kits)
- Platform label (auto-detected from kit)
- Barcode location segmented control (5', 3', Both Ends)
- Symmetry mode popup (Symmetric, Asymmetric, Single End)
- Error rate field (pre-filled from platform default)
- `[Scout This Step]` button
- Per-barcode table showing individual barcodes from selected kit

For single-step demux (the common case), the step list shows one row and
the detail panel fills most of the space -- functionally identical to the
current Barcode Sets tab but with platform-aware context.

#### Barcode Kits Tab (renamed from Barcode Sets)

- Browse built-in kits by platform
- View individual barcode sequences within each kit
- Import custom kits from CSV/FASTA
- No demux configuration here; this is read-only browsing + custom kit mgmt

#### Samples Tab

Unchanged. Shows per-sample barcode assignments and CSV import/export.
For multi-step demux, adds a "Composite Names" section at the bottom
mapping outer+inner barcode combos to sample names.

### 6.2 Barcode Kit Browser

In the Barcode Kits tab, when a kit is selected, show its barcodes in a
detail table:

| ID | Sequence | Secondary | Sample |
|----|----------|-----------|--------|
| BC01 | AAGAAAGTTGTCGGTGTCTTTGTG | | |
| BC02 | TCGATTCCGTTTGTAGTCGTCTGT | | |

This addresses the user's request to "see individual barcode sequences"
within each kit from the drawer.

---

## Part 7: Cutadapt Invocation Changes

### 7.1 Adapter FASTA Generation

Replace `generateCutadaptFASTA` in `IlluminaBarcodeKitRegistry` with a
platform-aware version:

```swift
public static func generateCutadaptFASTA(
    for kit: BarcodeKitDefinition,
    to url: URL,
    context: any PlatformAdapterContext,
    symmetryMode: BarcodeSymmetryMode,
    selectedBarcodeIDs: Set<String>? = nil  // nil = all barcodes
) throws
```

**For symmetric mode (ONT native, PacBio symmetric):**

Each barcode gets a linked adapter entry:
```
>BC01
AATGTACTTCGTTCAGTTACGTATTGCTAAGAAAGTTGTCGGTGTCTTTGTGCAGCACCT...AGGTGCTGCACAAAGACACCGACAACTTTCTTAGCAATACGTAACTGAACGAAGT
>BC02
AATGTACTTCGTTCAGTTACGTATTGCTTCGATTCCGTTTGTAGTCGTCTGTCAGCACCT...AGGTGCTGACAGACGACTACAAACGGAATCGAAGCAATACGTAACTGAACGAAGT
```

**For asymmetric mode:**

Separate 5' and 3' adapter files:
```
# 5prime-adapters.fasta
>bc1003_fwd
ACACATCTCGTGAGAG
>bc1016_fwd
CATATATATCAGCTGT

# 3prime-adapters.fasta
>bc1003_rev
CTCTCACGAGATGTGT
>bc1016_rev
ACAGCTGATATATAT
```

### 7.2 Cutadapt Command Construction

```swift
func buildCutadaptCommand(config: DemultiplexConfig) -> [String] {
    var args = ["cutadapt"]

    // Platform-specific error rate
    args += ["-e", String(config.errorRate)]

    // Overlap
    args += ["--overlap", String(config.minimumOverlap)]

    // Reverse complement search for long-read platforms
    if config.searchReverseComplement {
        args += ["--revcomp"]
    }

    // Action
    if config.trimBarcodes {
        args += ["--action", "trim"]
    } else {
        args += ["--action", "none"]
    }

    // Adapter specification depends on symmetry mode
    switch config.symmetryMode {
    case .symmetric, .singleEnd:
        args += ["-g", "file:\(adapterFastaPath)"]
    case .asymmetric:
        args += ["-g", "file:\(fivePrimeAdapterPath)"]
        args += ["-a", "file:\(threePrimeAdapterPath)"]
    }

    // Output
    args += ["-o", "\(outputDir)/{name}.fastq.gz"]
    args += ["--untrimmed-output", "\(outputDir)/unassigned.fastq.gz"]

    // Threads
    args += ["-j", String(config.threads)]

    // JSON report for scout parsing
    args += ["--json", "\(outputDir)/cutadapt-report.json"]

    // Input
    args += [inputPath]

    return args
}
```

---

## Part 8: Platform Support Matrix

| Platform | Demux by App | Adapter Trim | Barcode Trim | cutadapt Flags |
|----------|-------------|--------------|--------------|----------------|
| ONT Native | Yes (linked adapters) | Included in linked spec | Yes | `-e 0.20 --revcomp --overlap 20` |
| ONT Rapid | Yes (linked adapters) | Included in linked spec | Yes | `-e 0.20 --revcomp --overlap 20` |
| PacBio HiFi | Yes (linked adapters) | N/A (CCS removes) | Yes | `-e 0.10 --revcomp --overlap 14` |
| Illumina | No (bcl2fastq) | Yes (read-through) | N/A | `-e 0.10 -a ADAPTER` |
| Element | No (bases2fastq) | Yes (TruSeq compat) | N/A | `-e 0.10 -a ADAPTER --nextseq-trim=20` |
| Ultima | No (Ultima pipeline) | Yes (TruSeq compat) | N/A | `-e 0.10 -a ADAPTER` |
| MGI | No (zebracallV2) | Yes (MGI adapters) | N/A | `-e 0.10 -a ADAPTER` |

"Demux by App" = the app runs cutadapt to split reads by barcode.
"Adapter Trim" = remove platform adapter read-through contamination.
"Barcode Trim" = remove barcode sequences from read ends.

For platforms with `indexesInSeparateReads == true`, demultiplexing is
already done before the user has FASTQ files. The app only needs to trim
residual adapter read-through.

---

## Part 9: Implementation Order

### Phase 1: Foundation (fix the barcode05 bug)
1. Create `PlatformAdapters.swift` with embedded adapter constants
2. Create `PlatformAdapterContext.swift` protocol + implementations
3. Create `SequencingPlatform.swift` enum
4. Create `BarcodeKitType.swift` enum
5. Refactor `generateCutadaptFASTA` to use `PlatformAdapterContext`
6. Add `sequencingPlatform` to `PersistedFASTQMetadata`
7. **Test**: ONT barcode13 test file demuxes correctly with native adapter context

### Phase 2: Type renames and generalization
1. Create `BarcodeEntry` (with `IlluminaBarcode` typealias)
2. Create `BarcodeKitDefinition` (with `IlluminaBarcodeDefinition` typealias)
3. Add `BarcodeSymmetryMode` to `DemultiplexConfig`
4. Add `searchReverseComplement` to `DemultiplexConfig`
5. Add `adapterContext` to `DemultiplexConfig`
6. Update `DemultiplexingPipeline.run()` to use new config fields
7. Update existing tests

### Phase 3: Barcode scouting
1. Create `BarcodeScoutResult` / `BarcodeDetection` models
2. Implement `DemultiplexingPipeline.scout()` method
3. Create `BarcodeScoutSheet` (NSViewController with modal sheet)
4. Wire scout sheet into FASTQ viewer
5. Persistence: save/load `scout-result.json`

### Phase 4: Multi-step demux
1. Create `DemultiplexStep` / `DemultiplexPlan` models
2. Implement `DemultiplexingPipeline.runMultiStep()` method
3. Create `MultiStepDemultiplexResult` model
4. Update `DemultiplexManifest` for multi-step provenance

### Phase 5: UI overhaul
1. Rename Barcode Sets tab -> Barcode Kits tab
2. Add barcode sequence browser to Barcode Kits tab
3. Create Demux Setup tab with step list + detail panel
4. Add composite sample name mapping for multi-step
5. Wire scout button per step
6. Add platform selector to import dialogs

### Phase 6: Additional platforms
1. Add Element AVITI adapter trimming support
2. Add Ultima Genomics adapter trimming support
3. Add MGI/DNBSEQ adapter trimming support
4. Add SMRTbell contamination QC check for PacBio
5. Add poly-G trimming option for two-color platforms

---

## Part 10: Files to Create

| File | Module | Purpose |
|------|--------|---------|
| `SequencingPlatform.swift` | LungfishIO | Platform enum with capabilities |
| `PlatformAdapters.swift` | LungfishIO | Embedded adapter sequence constants |
| `PlatformAdapterContext.swift` | LungfishIO | Protocol + per-platform implementations |
| `BarcodeKitType.swift` | LungfishIO | Kit type classification enum |
| `BarcodeScoutResult.swift` | LungfishIO | Scout result data model |
| `DemultiplexPlan.swift` | LungfishWorkflow | Multi-step plan model |
| `BarcodeScoutSheet.swift` | LungfishApp | Scout results UI (modal sheet) |
| `DemuxSetupView.swift` | LungfishApp | Demux Setup tab in bottom drawer |
| `BarcodeKitBrowserView.swift` | LungfishApp | Kit browsing with individual sequences |

## Part 11: Files to Modify

| File | Changes |
|------|---------|
| `IlluminaBarcodeKits.swift` | Add typealiases, add `platform`/`kitType` to definitions |
| `DemultiplexingPipeline.swift` | Use `PlatformAdapterContext`, add `scout()`, add `runMultiStep()` |
| `FASTQMetadataStore.swift` | Add `sequencingPlatform` field |
| `FASTQMetadataDrawerView.swift` | Restructure tabs, add Demux Setup |
| `DemultiplexManifest.swift` | Add multi-step support |
| `ONTDirectoryImporter.swift` | Set `sequencingPlatform = .oxfordNanopore` on import |

---

## Appendix A: ONT Barcode Read Structure Reference

### Native Barcoding (SQK-NBD114)
```
5'-[Y-adapter top: AATGTACTTCGTTCAGTTACGTATTGCT]
   [Barcode forward: 24 bp, kit-specific]
   [5' flank: CAGCACCT]
   [INSERT]
   [3' flank: AGGTGCTG]
   [Barcode reverse complement: 24 bp]
   [Y-adapter bottom: AGCAATACGTAACTGAACGAAGT]-3'
```

### Rapid Barcoding (SQK-RBK114)
```
5'-[Rapid adapter: GGCGTCTGCTTGGGTGTTTAACCTTTTTTTTTTAATGTACTTCGTTCAGTTACGTATTGCT]
   [Barcode forward: 24 bp]
   [ME: AGATGTGTATAAGAGACAG]
   [INSERT]
   [ME_rc: CTGTCTCTTATACACATCT]
   [Barcode reverse complement: 24 bp]
   [Rapid adapter rc]-3'
```

## Appendix B: Key Adapter Sequences Quick Reference

```
ONT Y-adapter top:     AATGTACTTCGTTCAGTTACGTATTGCT
ONT native flank 5':   CAGCACCT
ONT native flank 3':   AGGTGCTG
ONT rapid adapter:     GGCGTCTGCTTGGGTGTTTAACCTTTTTTTTTTAATGTACTTCGTTCAGTTACGTATTGCT
ONT transposase ME:    AGATGTGTATAAGAGACAG

Illumina TruSeq R1:    AGATCGGAAGAGCACACGTCTGAACTCCAGTCA
Illumina TruSeq R2:    AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT
Illumina Nextera R1:   CTGTCTCTTATACACATCTCCGAGCCCACGAGAC
Illumina Nextera R2:   CTGTCTCTTATACACATCTGACGCTGCCGACGA
Illumina universal:    AGATCGGAAGAG

PacBio SMRTbell v3:    AAAAAAAAAAAAAAAAAATTAACGGAGGAGGAGGA
PacBio SMRTbell v2:    AAGTCACAGCGGAACGGCGA
PacBio SMRTbell v1:    ATCTCTCTCTTTTCCTCCTCCTCCGTTGTTGTTGTTGAGAGAGAT

MGI R1:                AAGTCGGAGGCCAAGCGGTCTTAGGAAGACAA
MGI R2:                AAGTCGGATCGTAGCCATGTCGTTCTGTGAGCCAAGGAGTTG
```

Element AVITI and Ultima Genomics use TruSeq-identical adapters by design.
