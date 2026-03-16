# Expert Consensus Plan: Cross-Platform Demultiplexing Fix

## Reviewing Experts
- **Sequencing Expert**: Reviewed platform-specific error profiles, barcode set design, and expected assignment ceilings
- **Bioinformatics/Cutadapt Expert**: Reviewed cutadapt parameter semantics, code-level bugs, and adapter syntax interactions

## Key Findings (Consensus)

### Root Cause
PacBio barcode kits on ONT reads get PacBio platform defaults (`-e 0.10 --overlap 14`), which are catastrophically strict for ONT error profiles. The `--overlap 14` on 16bp barcodes requires 14/16 bases to align — this alone explains the 7.6% assignment rate.

### Why `--no-indels` Works
Both experts agree: cutadapt's indel-aware aligner paradoxically *hurts* performance on short barcodes with ONT error profiles. ONT indels in homopolymer runs shift the alignment frame, causing cutadapt's semi-global aligner to reject true matches. Switching to Hamming-only matching (`--no-indels`) converts cutadapt into a substring search that tolerates the substitution-dominant error profile at adapter junctions.

### Why Flanking Context Hurts
Cutadapt treats the entire adapter spec as one unit for error rate calculation. A 16bp barcode with `-e 0.15` allows 2 mismatches. Adding 30bp of inner flank creates a 46bp spec allowing 6 mismatches total — but errors cluster in the barcode, not the conserved flank, causing alignment failures. Bare barcodes are correct.

### Expected Ceiling
- **Paired barcode assignment**: 50-55% (validated by sweep at 56.5%)
- **Single-barcode detection**: 85-90% (5' end only)
- **Ground truth**: 54.3% both barcodes, 37.4% mapped to known sample pairs
- **Unexpected pairs**: 16.9% — likely chimeric reads from ONT ligation

## Bugs Found (Priority Order)

### BUG 1 (Critical): Scout uses raw kit.platform defaults
**File**: `DemultiplexingPipeline.swift`, lines 1474-1475
```swift
args += ["-e", String(kit.platform.recommendedErrorRate)]     // PacBio: 0.10, should be 0.15
args += ["--overlap", String(kit.platform.recommendedMinimumOverlap)]  // PacBio: 14, should be 12
// Missing: --no-indels
```
The scout function has no `sourcePlatform` parameter and cannot compute cross-platform corrections. This means the scout predicts 7.6% assignment while the full demux achieves 56.5%.

### BUG 2 (Critical): Scout phase 2 missing reverse orientation
**File**: `DemultiplexingPipeline.swift`, lines 1403-1413
The combinatorial phase 2 scout generates only one orientation per pair (`fwd...rev`). The full demux path (lines 648-671) correctly generates both orientations (`fwd...rev` AND `rev...fwd`). This means ~50% of reverse-oriented reads go unassigned in the scout.

### BUG 3 (High): effectiveMinimumOverlap uses wrong field
**File**: `DemultiplexingPipeline.swift`, lines 111-115
Uses `barcodeKit.barcodes.first?.i7Sequence.count` — only checks the first barcode's i7. Should use minimum length across all barcodes and both i7/i5 sequences.

### BUG 4 (Medium): Scout uses `--action trim` unnecessarily
**File**: `DemultiplexingPipeline.swift`, line 1479
Scout only needs hit counts, not trimmed sequences. Using `--action none` is faster and avoids edge cases.

## Recommended Parameters

### Cross-platform (ONT reads + PacBio barcodes, 16bp)
| Parameter | Value | Rationale |
|---|---|---|
| `-e` | 0.15 | 2 mismatches in 16bp; matches ONT error at adapter junctions |
| `--overlap` | 12 | barcodeLen - 4 = 12; allows partial boundary matches |
| `--no-indels` | yes | Hamming-only; avoids indel-induced alignment failures |
| Adapter spec | bare barcode | No flanking context (kills matching) |
| Orientation | both in FASTA | `fwd...rev` AND `rev...fwd` per pair (not `--revcomp`) |

### Native platform (matching kit and read platform)
| Scenario | Error Rate | Overlap | Indels |
|---|---|---|---|
| ONT barcodes on ONT reads | 0.15 | 20 | allowed |
| PacBio barcodes on PacBio reads | 0.10 | 14 | allowed |
| Illumina barcodes on Illumina reads | 0.10 | 5 | allowed |

### Cross-platform logic
```
useNoIndels = sourcePlatform != kit.platform AND isLongRead AND barcodeLen <= 24
effectiveErrorRate = max(configured, sourcePlatform.recommendedErrorRate)
effectiveOverlap = min(configured, max(3, minBarcodeLen - 4))
```

## Implementation Plan (Phased with Checkpoints)

### Phase 1: Fix Scout Parameters
**Goal**: Scout and full demux use identical effective parameters.

1. Add `sourcePlatform: SequencingPlatform?` parameter to `scout()` and `scoutCombinatorial()`
2. Replace hardcoded `kit.platform.recommendedErrorRate` / `recommendedMinimumOverlap` in `runScoutCutadapt` with effective parameters computed from sourcePlatform
3. Add `--no-indels` to scout when `useNoIndels` would be true
4. Change scout `--action trim` to `--action none`

**Checkpoint**: `swift build` passes. Manual test: scout a PacBio kit on ONT reads, verify parameters in log output match full demux parameters.

### Phase 2: Fix Scout Phase 2 Orientations
**Goal**: Scout phase 2 generates both orientations for long-read platforms.

1. In `scoutCombinatorial` phase 2 loop, add reverse orientation block mirroring full demux logic (lines 664-670)
2. Only generate reverse orientation when `fwd.i7Sequence != rev.i7Sequence` (same guard as full demux)

**Checkpoint**: `swift build` + `swift test` pass. Verify adapter FASTA has 2x entries for asymmetric pairs.

### Phase 3: Fix effectiveMinimumOverlap
**Goal**: Use minimum barcode length across all barcodes and both indices.

1. Replace `barcodeKit.barcodes.first?.i7Sequence.count` with `min` across all barcodes' i7 and i5 lengths
2. Handle edge case where barcodes array is empty (fallback to 16)

**Checkpoint**: `swift build` + `swift test` pass.

### Phase 4: Add Trim Position Capture (for virtual demux export)
**Goal**: Materialized FASTQs have adapters/barcodes/primers removed.

1. Add `--info-file` to cutadapt invocation in `run()` method
2. Parse info file: extract per-read trim coordinates (match start/end positions)
3. Write `trim-positions.tsv` in each virtual barcode bundle
4. Update `FASTQDerivativePayload.demuxedVirtual` to include `trimPositionsFilename`
5. Update materialization to apply trim coordinates when extracting reads

**Checkpoint**: `swift build` + `swift test` pass. End-to-end: demux → export → verify trimmed output.

### Phase 5: Testing & QA
1. Verify parameter sweep reproduction: PacBio 384 on ONT reads should yield ~50-55% assignment
2. Verify scout prediction matches full demux within 5%
3. Verify both orientations detected in scout phase 2
4. Verify trimmed exports have correct start/end positions
5. Run full test suite

## Future Considerations (Not in Scope)
- **Per-read confidence scoring**: Hamming distance margin between assigned and next-best barcode
- **Chimera detection**: Flag reads where 5' and 3' barcodes map to different samples with high confidence
- **Single-end fallback**: Option to assign reads with only one barcode detected (~85% sensitivity)
- **Native barcode matcher**: Two-stage anchor + Hamming approach for cross-platform scenarios (would exceed cutadapt's performance)
