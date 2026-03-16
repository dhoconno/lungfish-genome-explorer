# FASTQ Operations Redesign Plan

## Date: 2026-03-11
## Status: Expert-Reviewed, Ready for Implementation

---

## Executive Summary

After two days of iterating on demultiplexing and orient features, and comprehensive expert analysis of commercial/open-source tools (Dorado, Lima, Geneious, CLC, Porechop, BBDuk), this plan addresses the core problems:

1. **Orient is tangled with demux** — it should be a standalone FASTQ operation
2. **Demux barcode detection is unreliable** — cutadapt orientation handling has bugs
3. **No parent-child hierarchy** — demuxed results should be children under the parent FASTQ
4. **Separation of concerns** — demux, trim, orient should be independent operations (Geneious pattern)

### Key Expert Finding

**No major tool uses cutadapt as its primary demux engine.** However, cutadapt is the best option among our bundled tools (cutadapt, bbduk, seqkit, vsearch) for this task. BBDuk cannot handle linked adapters, positional constraints, or ONT error profiles. The right approach is to **fix cutadapt usage**, not switch tools.

### Tool Decision Matrix (Expert Consensus)

| Task | Best Tool | Runner-Up | Avoid |
|------|-----------|-----------|-------|
| ONT symmetric demux | **cutadapt** | - | bbduk |
| Asymmetric demux (small set) | **cutadapt** linked | - | bbduk |
| Asymmetric demux (384x384) | **cutadapt + vsearch** | - | bbduk |
| Illumina adapter trim | **bbduk** | cutadapt | - |
| ONT/PacBio adapter trim | **cutadapt** | - | bbduk |
| Primer trimming | **cutadapt** | - | bbduk (no IUPAC) |
| Read orientation | **vsearch** `--orient` | cutadapt `--revcomp` | - |
| QC/stats/filtering | **seqkit** | - | - |

---

## Problem Analysis

### Problem 1: Orient is Entangled with Demux

**Current state:** Orient has its own tab in the drawer (tab 2) but the notification flow goes through `FASTQDatasetViewController` which dispatches to `FASTQDerivativeService`. The UI is awkward — it's a drawer tab alongside "Samples", "Demux Setup", and "Barcode Kits" when it should be a top-level operation.

**Fix:** Move orient to the operations sidebar alongside other FASTQ operations (subsample, filter, trim, etc.). Remove the Orient tab from the drawer entirely.

### Problem 2: Demux Barcode Orientation Handling

**Current state:** The pipeline uses `--revcomp` flag for long-read platforms, which tells cutadapt to reverse-complement the entire read if an adapter is found on the reverse strand. This works for the first barcode but creates problems for dual-barcode detection:

- For ONT native barcoding, barcodes appear in 4 configurations:
  1. `BC_fwd ... RC(BC_fwd)` — template strand read 5'→3'
  2. `RC(BC_fwd) ... BC_fwd` — complement strand read 5'→3'
  3. `BC_A ... RC(BC_B)` — asymmetric, template strand
  4. `RC(BC_B) ... BC_A` — asymmetric, complement strand

- The current multi-pass approach (Pass 1: detect with --revcomp, Pass 2a: trim 5', Pass 2b: validate 3') is conceptually correct but has bugs in the scout function:
  - Scout uses raw `kit.platform` defaults instead of cross-platform effective parameters
  - Scout phase 2 generates only one orientation per pair (missing ~50% of reverse-oriented reads)
  - `useNoIndels` returns `true` for ONT + short barcodes, but our benchmarking proved indels MUST be allowed

**Fix:** Apply the 4 bugs identified in `demux-expert-consensus-plan.md`. The underlying cutadapt approach is sound — it just has implementation bugs.

### Problem 3: No Parent-Child Hierarchy

**Current state:** Demuxed bundles are created as `.lungfishfastq` bundles in the output directory. They reference the root FASTQ via `rootBundleURL` in the manifest. But in the filesystem and sidebar, they appear as independent files.

**Fix:** Create demuxed results as a subfolder under the parent FASTQ bundle. The sidebar shows expandable groups. This matches Dorado/Lima's per-barcode output structure but with virtual (read-ID-based) storage.

### Problem 4: Cutadapt Adapter Spec Issues

**Current state:** `ONTNativeAdapterContext` builds adapter specs as: `Y-adapter + outer_flank + barcode + rear_flank` (67bp total). Our benchmarking proved the rear flank concatenation is correct, but the full spec (with Y-adapter + outer flank) may be causing issues because:
- Cutadapt treats the entire adapter as one unit for error rate calculation
- A 67bp spec with `-e 0.15` allows 10 mismatches — but errors cluster in specific regions
- The expert consensus plan says: "bare barcodes are correct" for cross-platform scenarios

**Fix:** For cross-platform scenarios (PacBio barcodes on ONT reads), use bare barcodes. For native platform scenarios (ONT barcodes on ONT reads), the full adapter spec with rear flank is correct. The `PlatformAdapterContext` should handle this distinction.

---

## Implementation Plan

### Phase 1: Move Orient to Operations Sidebar (Low Risk)

**Goal:** Orient becomes a first-class FASTQ operation, not a drawer tab.

**Files to modify:**

1. **`FASTQDatasetViewController.swift`** — Add orient to the operations sidebar
   - Add `OperationKind.orient` case
   - Add orient parameter UI (reference popup, word length, masking, save-unoriented checkbox)
   - Wire the "Apply" button to dispatch `.orient(...)` request
   - Remove the orient notification observer (no longer needed — direct dispatch)

2. **`FASTQMetadataDrawerView.swift`** — Remove orient tab
   - Remove tab 2 (Orient) from the segmented control
   - Remove `orientContainer`, `orientConstraints`, all orient-related controls
   - Remove orient action handlers (`orientBrowseClicked`, `orientRunClicked`, etc.)
   - Remove `rebuildOrientReferencePopup()`
   - Simplify tab indices: 0=Samples, 1=Demux Setup, 2=Barcode Kits

3. **`Notifications.swift`** — Remove `.fastqOrientRequested` notification
   - No longer needed since orient dispatches directly through the operations sidebar

**Checkpoint:** Build succeeds. Orient works from operations sidebar. Drawer has 3 tabs.

### Phase 2: Fix Demux Bugs (Critical, High Value)

**Goal:** Scout and full demux produce consistent, correct results for all platform combinations.

**Files to modify:**

1. **`DemultiplexingPipeline.swift`** — Fix the 4 identified bugs:

   **Bug 1: Scout uses raw kit.platform defaults**
   - Add `sourcePlatform: SequencingPlatform?` parameter to `scout()` and `scoutCombinatorial()`
   - In `runScoutCutadapt()`, replace `kit.platform.recommendedErrorRate` / `recommendedMinimumOverlap` with effective parameters computed the same way as `DemultiplexConfig`
   - This ensures scout predicts the same rate as the full demux

   **Bug 2: Scout phase 2 missing reverse orientation**
   - In `scoutCombinatorial()` phase 2 loop, add reverse orientation block
   - For each pair (fwd, rev), also generate (rev, fwd) entry in the adapter FASTA
   - Guard: only when `fwd.i7Sequence != rev.i7Sequence` (same as full demux)

   **Bug 3: `effectiveMinimumOverlap` uses wrong field**
   - Replace `barcodeKit.barcodes.first?.i7Sequence.count` with minimum across ALL barcodes' i7 AND i5 lengths
   - Handle empty barcodes array (fallback to 16)

   **Bug 4: Scout uses `--action trim` unnecessarily**
   - Change to `--action none` — scout only needs hit counts, not trimmed reads

2. **`DemultiplexingPipeline.swift`** — Fix `useNoIndels`:
   - Change the computed property to return `false` always (or make it configurable via `DemultiplexConfig.allowIndels`)
   - Our ONT benchmarking proved: allowing indels improved detection by 18%
   - The `--no-indels` flag is only appropriate for Illumina data

3. **`DemultiplexConfig`** — Add `allowIndels: Bool` parameter (default `true`)
   - Replace the computed `useNoIndels` heuristic with explicit user control
   - For Illumina: UI can default to `false` (Hamming matching is fine)
   - For ONT/PacBio: UI defaults to `true`

**Checkpoint:** Build + tests pass. Scout on PacBio kit with ONT reads matches full demux within 5%. Both orientations detected in scout phase 2.

### Phase 3: Parent-Child Filesystem Layout

**Goal:** Demuxed results live as children under the parent FASTQ bundle.

**Design (inspired by Dorado/Lima output):**
```
parent.fastq.gz
parent.lungfishfastq/
  derived-manifest.json          # Root manifest
  statistics-cache.json
  demux/                         # Demux results folder
    demux-manifest.json          # Summary: barcode counts, parameters
    barcode01/                   # Per-barcode subfolder
      derived-manifest.json
      read-ids.txt
      preview.fastq.gz
      trim-positions.tsv
    barcode02/
      ...
    unassigned/
      derived-manifest.json
      read-ids.txt
      preview.fastq.gz
```

**Files to modify:**

1. **`FASTQDerivatives.swift`** — Update payload model
   - Add `FASTQDerivativePayload.demuxFolder(manifestFilename: String)` for the parent-level demux result
   - Update `.demuxedVirtual` to include `parentDemuxFolder: String` reference
   - The `demuxFolder` payload replaces `.demuxGroup`

2. **`DemultiplexingPipeline.swift`** — Change output directory structure
   - Create per-barcode bundles inside `parent.lungfishfastq/demux/` instead of a flat output directory
   - Write `demux-manifest.json` summarizing all barcodes

3. **`FASTQDerivativeService.swift`** — Update materialization paths
   - When materializing a demuxed read set, resolve paths relative to the parent bundle
   - Update `createDemultiplexDerivative()` to write into the parent bundle's `demux/` subfolder

4. **`FASTQDatasetViewController.swift`** — Show demux children in sidebar
   - When a FASTQ bundle has a `demux/` subfolder, show as expandable group in the sidebar
   - Clicking a barcode child loads its derived manifest and statistics

**Checkpoint:** Build succeeds. Demux creates children under parent. Sidebar shows expandable barcode groups.

### Phase 4: Separate Demux from Trim (Geneious Pattern)

**Goal:** Clear separation: Step 1 = identify and split by barcode. Step 2 = trim adapters/barcodes (optional, separate operation).

**Current state:** The `DemultiplexStep` has both barcode identification AND trim settings (`trimBarcodes`, adapter context). The `buildCutadaptArguments()` method combines both.

**Fix:** Keep the current multi-step architecture but clarify the UI:
- Demux step: `--action none` by default (classify only, don't trim)
- Trim step: separate operation in the operations sidebar
- User can choose to combine (for convenience) or keep separate (for inspection)

This is a UI/UX change primarily — the pipeline already supports `--action none`.

**Files to modify:**

1. **`FASTQMetadataDrawerView.swift`** — Simplify demux setup
   - Default `trimBarcodes` to `false` (classify only)
   - Add explanatory label: "Barcodes will be identified but not removed. Use the Trim operation to remove barcodes after demux."
   - Add a "Trim barcodes during demux" checkbox for users who want combined

2. **`FASTQDatasetViewController.swift`** — Add explicit trim operation
   - Operations sidebar already has trim operations
   - Ensure "Adapter Trim" and "Primer Trim" work on demuxed children

**Checkpoint:** Build succeeds. Default demux classifies without trimming. Trim works as separate step.

### Phase 5: ONT Rear Flank Concatenation

**Goal:** Apply the validated rear flank concatenation from benchmarking.

**Files to modify:**

1. **`PlatformAdapterContext.swift`** — `ONTNativeAdapterContext`
   - `fivePrimeSpec()`: Append `CAGCACCT` after the barcode
   - `threePrimeSpec()`: Prepend `AGGTGCTG` before the barcode RC
   - Update doc comments to explain the concatenation rationale
   - Leave `ONTRapidAdapterContext` unchanged (rapid kits have no rear flank)

2. **`PlatformAdapters.swift`** — Constants already exist
   - `ontNativeBarcodeFlank5` = `CAGCACCT` and `ontNativeBarcodeFlank3` = `AGGTGCTG` already defined
   - No changes needed

**Checkpoint:** Build succeeds. Adapter spec for ONT native includes rear flank.

---

## Expert Validation Checklist

### Before Phase 2 implementation:
- [ ] Verify `effectiveErrorRate` formula matches expert consensus (max of configured and source platform)
- [ ] Verify `effectiveMinimumOverlap` uses min across all barcodes and both indices
- [ ] Verify scout generates both orientations for asymmetric pairs
- [ ] Verify `--no-indels` is NOT added for ONT data

### Before Phase 3 implementation:
- [ ] Verify parent-child path resolution works with `.lungfishfastq` bundle structure
- [ ] Verify materialization can find root FASTQ from nested demux child
- [ ] Verify sidebar correctly discovers and displays demux children

### End-to-end validation:
- [ ] ONT native symmetric: Scout detects barcodes at 50%+ rate, full demux matches
- [ ] ONT + PacBio asymmetric: Both barcode orientations detected
- [ ] Illumina: Standard paired-end demux still works
- [ ] Orient from operations sidebar: vsearch orient works as before
- [ ] Demux children visible in sidebar as expandable group

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Phase 1 (orient move) breaks existing orient functionality | Keep orient pipeline code unchanged; only UI routing changes |
| Phase 2 (bug fixes) changes demux behavior | Scout prediction should now MATCH full demux (improvement, not regression) |
| Phase 3 (filesystem) breaks existing derivative loading | Version the manifest format; support both flat and nested layouts |
| Phase 4 (separate trim) confuses users | Default to combined mode; separate is opt-in |
| Phase 5 (flank concatenation) changes adapter matching | Only affects ONT native kits; validates against benchmark data |

---

## Implementation Order

Phases are ordered by risk (lowest first) and dependency:

1. **Phase 1** (Orient → sidebar) — Independent, low risk, immediate UX improvement
2. **Phase 2** (Bug fixes) — Critical correctness fixes, no architecture changes
3. **Phase 5** (Flank concatenation) — Small change, validated by benchmarks
4. **Phase 3** (Filesystem layout) — Architecture change, but scoped to demux output
5. **Phase 4** (Separate trim) — UX polish, depends on Phase 3 being stable

Total estimated scope: ~500-800 lines changed across 6-8 files.

---

## References

- [Demultiplexing Tools Comparative Analysis](demultiplexing-tools-comparative-analysis.md)
- [Demux Benchmark Report](demux-benchmark-report.md) — 21,748 read dataset
- [Cutadapt Demux Pipeline Spec](cutadapt-demux-pipeline-spec.md) — Empirical validation
- [Expert Consensus Plan](demux-expert-consensus-plan.md) — Bug identification
- [BBDuk Expert Analysis](../design/fastq-operations-redesign-plan.md#tool-decision-matrix) — Tool comparison
