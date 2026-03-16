# Unified FASTQ Operations Plan

## Consensus Design Document
**Date**: 2026-03-11
**Status**: Approved for implementation
**Scope**: Remove multi-step demux UI, add Orient Sequences operation, add Reference Sequences folder

---

## 1. Executive Summary

Three coordinated changes to simplify FASTQ operations:

1. **Replace multi-step demux with unified demux panel** — Primary + optional secondary barcode kit in a single tab, auto-chaining pipeline stages internally
2. **Add Orient Sequences operation** — vsearch `--orient` against a reference, with derivative FASTQ storage
3. **Add Reference Sequences project folder** — Persistent storage for reference FASTA files used by orient, mapping, etc.

---

## 2. Architecture Overview

### 2.1 Pipeline Processing Order

```
Raw FASTQ
  ├─ Orient (optional, before demux)
  │   └─ vsearch --orient → oriented derivative + optional unoriented derivative
  │
  └─ Demultiplex (unified)
      ├─ Primary kit (e.g., ONT SQK-NBD114.96) → per-barcode bins
      └─ Secondary kit (optional, e.g., PacBio Sequel 384)
          └─ Runs on EACH primary bin → sub-bins (BC01/bc1003--bc1016)
```

**Key decision**: Orient BEFORE demux. Rationale:
- Orienting is a per-read operation that doesn't depend on barcode identity
- After orienting, all reads are in consistent forward orientation
- Demux with `--revcomp` still works on oriented reads (some may have been RC'd)
- Orient only once on the full dataset, not N times on each barcode bin

### 2.2 Reference Sequences Folder

```
MyProject.lungfishproject/
  ├─ Reference Sequences/          ← NEW folder
  │   ├─ MyAmplicon.lungfishref/   ← imported reference bundle
  │   │   ├─ manifest.json
  │   │   └─ sequence.fasta
  │   └─ 16S_reference.lungfishref/
  │       ├─ manifest.json
  │       └─ sequence.fasta
  ├─ FASTQ Data/
  │   ├─ sample1.lungfishfastq/
  │   └─ sample1.lungfishfastq/Derivatives/
  │       ├─ oriented.lungfishfastq/      ← orient derivative
  │       └─ demux-BC01.lungfishfastq/
  └─ Genomes/
```

When a user selects an external reference file:
1. Copy the FASTA into a new `.lungfishref` bundle in `Reference Sequences/`
2. Store the bundle-relative path in the orient operation metadata
3. Future operations reference the project-local copy

### 2.3 Derivative FASTQ for Orient

Orient results are stored as a **lightweight derivative**, not a full copy:

- **Payload type**: New `.orientMap` payload — stores a TSV mapping read IDs to orientation
- **Format**: `read_id\torientation\n` where orientation is `+` (already forward) or `-` (was RC'd)
- **Materialization**: When the oriented FASTQ is needed downstream, use `seqkit seq --reverse --complement` on the `-` reads only
- **Unoriented reads**: If user opts to save them, stored as a subset derivative (read ID list of unmatched reads)

This is scientifically sound because:
- vsearch orient only determines direction; it doesn't modify sequence content
- `seqkit seq -rp` correctly reverses both sequence AND quality scores
- The original read data is preserved in the root FASTQ

---

## 3. vsearch Orient Pipeline

### 3.1 Command

```bash
vsearch \
  --orient input.fastq \
  --db reference.fasta \
  --fastqout oriented.fastq \
  --notmatched unoriented.fastq \
  --tabbedout orient-results.tsv \
  --threads 0
```

### 3.2 Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `--db` | required | Reference FASTA in correct orientation |
| `--wordlength` | 12 | Word size for k-mer matching (3-15). Default 12 is good for amplicons >200bp |
| `--dbmask` | dust | Mask low-complexity in reference. Use `none` for short amplicons (<500bp) |
| `--qmask` | dust | Mask low-complexity in queries. Use `none` for short amplicons |
| `--threads` | 0 (all) | Parallelize across cores |

### 3.3 Output

- `--fastqout`: Oriented reads (quality scores preserved; RC'd reads get reversed quality)
- `--notmatched`: Reads that couldn't be oriented (no significant match to reference)
- `--tabbedout`: TSV with columns: `query_label`, `orientation` (+/-/?), `db_match_label`

### 3.4 Reference Requirements

- Must be FASTA format (not FASTQ)
- Should be the amplicon or gene of interest in the DESIRED forward orientation
- Single sequence is sufficient for amplicon work
- For multi-gene panels, include one representative per amplicon
- Minimum ~100bp for reliable orientation (k-mer matching needs sufficient sequence)

### 3.5 Derivative Storage (Lightweight)

Instead of storing the full oriented FASTQ, store only the orientation map:

```
oriented.lungfishfastq/
  ├─ manifest.json          (FASTQDerivedBundleManifest with .orientMap payload)
  ├─ orient-map.tsv         (read_id → +/- orientation)
  └─ preview.fastq          (first 1000 oriented reads for quick display)
```

**Materialization on demand**: When downstream tools need the oriented FASTQ:
1. Read orient-map.tsv
2. Stream through root FASTQ
3. For reads marked `-`, apply `seqkit seq -rp` (reverse complement with quality reversal)
4. Write to temp file or pipe

---

## 4. Unified Demultiplex Panel

### 4.1 Data Model Changes

**Remove**: `DemultiplexPlan` multi-step concept (steps array, ordinals, composite sample names)

**Replace with**: `DemultiplexConfig` gains optional `secondaryBarcodeKit`:

```swift
public struct DemultiplexConfig {
    // Primary barcode kit (required)
    let barcodeKit: BarcodeKitDefinition
    let symmetryMode: BarcodeSymmetryMode
    let errorRate: Double
    let minimumOverlap: Int
    let allowIndels: Bool
    let trimBarcodes: Bool
    let searchReverseComplement: Bool

    // Secondary barcode kit (optional — for dual-index workflows like ONT+PacBio)
    let secondaryBarcodeKit: BarcodeKitDefinition?
    let secondaryErrorRate: Double?
    let secondaryMinimumOverlap: Int?
    let secondaryAllowIndels: Bool?
    let secondaryTrimBarcodes: Bool?

    // Sample assignments
    let sampleAssignments: [FASTQSampleBarcodeAssignment]

    // Shared
    let unassignedDisposition: UnassignedDisposition
    let maxSearchDistance5Prime: Int
    let maxSearchDistance3Prime: Int
}
```

### 4.2 Pipeline Execution

When `secondaryBarcodeKit` is set:

1. **Pass 1**: Demux by primary kit → per-barcode output files
2. **Pass 2**: For each primary barcode bin, demux by secondary kit
3. **Output structure**: Nested bundles `BC01/bc1003--bc1016/`

The pipeline handles fan-out internally — no user interaction needed.

### 4.3 Secondary Kit Auto-Detection

When user selects a primary ONT kit AND a secondary PacBio kit:
- Auto-set primary parameters from ONT defaults (error 0.15, overlap 20, indels on)
- Auto-set secondary parameters from PacBio defaults (error 0.20, overlap 14, indels on)
- Show a summary: "ONT barcodes → PacBio barcodes (2-level demux)"

---

## 5. UI Design — Unified Bottom Drawer

### 5.1 Tab Structure

The bottom drawer has **two operation tabs** (replacing the old multi-step tabs):

```
┌─────────────────┬──────────────────┐
│  Demultiplex    │  Orient          │
└─────────────────┴──────────────────┘
```

### 5.2 Demultiplex Tab

```
┌──────────────────────────────────────────────────────────────┐
│ DEMULTIPLEX                                                   │
│                                                               │
│ Primary Barcode Kit:  [ONT SQK-NBD114.96        ▼]          │
│ Symmetry:            [Symmetric ▼]  ☑ Search RC              │
│ Error Rate: [0.15]   Min Overlap: [20]   ☑ Allow Indels      │
│ ☑ Trim Barcodes                                              │
│                                                               │
│ ┌─ Secondary Kit (optional) ──────────────────────────────┐  │
│ │ Secondary Barcode Kit:  [PacBio Sequel II 384   ▼]      │  │
│ │ Error Rate: [0.20]   Min Overlap: [14]   ☑ Allow Indels │  │
│ │ ☑ Trim Barcodes                                         │  │
│ │                                                         │  │
│ │ Pipeline: ONT outer → PacBio inner (auto-chained)       │  │
│ └─────────────────────────────────────────────────────────┘  │
│                                                               │
│ ┌─ Sample Assignments ────────────────────────────────────┐  │
│ │ [table of barcode→sample mappings]                      │  │
│ └─────────────────────────────────────────────────────────┘  │
│                                                               │
│ Unassigned reads: [Keep ▼]                                   │
│                                                               │
│ [Scout (100 reads)]                          [Demultiplex]   │
└──────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- Secondary kit section is collapsed by default, expandable with a disclosure triangle
- Parameters auto-populate from kit platform defaults
- "Pipeline" label shows users what will happen without requiring them to configure steps
- Scout runs the full pipeline (primary → secondary) on a subset

### 5.3 Orient Tab

```
┌──────────────────────────────────────────────────────────────┐
│ ORIENT SEQUENCES                                              │
│                                                               │
│ Reference:  [16S_reference.fasta      ] [Browse...] [Import] │
│             ℹ From project: Reference Sequences/16S_ref...    │
│                                                               │
│ Word Length: [12]    Masking: [dust ▼]                        │
│                                                               │
│ ☑ Save unoriented reads as separate derivative                │
│                                                               │
│ Results stored as lightweight derivative (orientation map).   │
│ Oriented FASTQ materialized on demand using seqkit.           │
│                                                               │
│                                                  [Orient]     │
└──────────────────────────────────────────────────────────────┘
```

**Reference selection flow:**
1. User clicks "Browse..." → file picker for FASTA files
2. If selected file is NOT in `Reference Sequences/`, show "Import" button
3. Import copies FASTA into a `.lungfishref` bundle in `Reference Sequences/`
4. Dropdown also lists existing project references

### 5.4 Barcode Kit Browser (Embedded)

The barcode kit selection popup shows:
- Kit name, platform, barcode count
- Clicking a kit auto-fills all parameters for that kit's platform
- Search/filter by platform or name

---

## 6. Implementation Phases

### Phase 1: Data Model & Reference Sequences (LungfishIO)

**Files to modify:**
- `FASTQDerivatives.swift` — Add `.orientMap` payload type, `orient` operation kind
- `FASTQDerivativeOperation` — Add orient parameters (referenceURL, wordLength, dbMask, saveUnoriented)

**Files to create:**
- `Sources/LungfishIO/Formats/Reference/ReferenceSequenceFolder.swift` — Manages `Reference Sequences/` folder
  - `ensureFolder(in projectURL:)` → creates folder if missing
  - `importReference(from sourceURL:, into projectURL:)` → copies FASTA into .lungfishref bundle
  - `listReferences(in projectURL:)` → lists available .lungfishref bundles
  - `referenceURL(bundleName:, in projectURL:)` → resolves FASTA path within bundle

**Files to modify for unified demux:**
- `DemultiplexPlan.swift` — Deprecate `DemultiplexStep` array; add `secondaryBarcodeKit` fields to a simpler config
- `DemultiplexingPipeline.swift` — Add secondary kit fan-out logic in `run()`

**Tests:**
- Test orient-map TSV read/write
- Test reference folder creation and import
- Test DemultiplexConfig with secondary kit

### Phase 2: Pipeline Implementation (LungfishWorkflow)

**Files to create:**
- `Sources/LungfishWorkflow/Orient/OrientPipeline.swift`
  - Runs vsearch `--orient`
  - Parses `--tabbedout` for orientation map
  - Creates derivative bundle with `.orientMap` payload
  - Optionally creates unoriented subset derivative

**Files to modify:**
- `DemultiplexingPipeline.swift` — Add secondary kit processing after primary demux
  - After primary demux creates per-barcode files, loop through each and run secondary demux
  - Create nested bundle structure (BC01/bc1003--bc1016/)
- `FASTQDerivativeService.swift` — Add `.orient` request type, wire to OrientPipeline
- `NativeToolRunner.swift` — Already has `.vsearch` tool; no changes needed

**Materialization support:**
- Add `OrientMaterializer` that reads orient-map.tsv and uses seqkit to RC marked reads
- Used when downstream operations need the actual oriented FASTQ bytes

**Tests:**
- Test vsearch orient command generation
- Test orient-map parsing
- Test materialization (seqkit RC on marked reads)
- Test secondary demux fan-out

### Phase 3: UI Redesign (LungfishApp)

**Files to modify:**
- `FASTQMetadataDrawerView.swift` — Major refactor:
  - Remove multi-step demux UI (step list, add/remove step buttons, step ordinals)
  - Replace with unified demux panel (primary kit + optional secondary kit)
  - Add Orient tab with reference selection, parameters, and run button
  - Add reference file picker and import flow

**Files to modify for reference selection:**
- `FASTQMetadataDrawerView.swift` — Add NSOpenPanel for reference FASTA selection
- Wire "Import" button to `ReferenceSequenceFolder.importReference()`
- Populate reference dropdown from `ReferenceSequenceFolder.listReferences()`

**UI controls to remove:**
- Step list table (stepTable)
- Add Step / Remove Step buttons
- Step ordinal stepper
- Step label field
- Multi-step plan model

**UI controls to add:**
- Secondary kit popup (initially hidden, disclosure triangle to expand)
- Secondary kit parameters (error rate, overlap, indels, trim)
- Orient tab with all orient controls
- Reference file picker/dropdown

---

## 7. Files Summary

### New Files
| File | Module | Purpose |
|------|--------|---------|
| `ReferenceSequenceFolder.swift` | LungfishIO | Reference Sequences folder management |
| `OrientPipeline.swift` | LungfishWorkflow | vsearch orient execution |
| `OrientMaterializer.swift` | LungfishWorkflow | On-demand oriented FASTQ generation |

### Modified Files
| File | Module | Changes |
|------|--------|---------|
| `FASTQDerivatives.swift` | LungfishIO | Add orient payload/operation types |
| `DemultiplexPlan.swift` | LungfishWorkflow | Simplify to unified config (keep for backward compat) |
| `DemultiplexingPipeline.swift` | LungfishWorkflow | Add secondary kit fan-out |
| `FASTQDerivativeService.swift` | LungfishApp | Add orient request handling |
| `FASTQMetadataDrawerView.swift` | LungfishApp | Remove multi-step, add unified demux + orient tabs |

### Deleted Concepts (not files)
- Multi-step DemultiplexPlan with ordered steps
- Step ordinals and composite sample names
- `multiStepDemultiplex` request type in FASTQDerivativeService

---

## 8. Migration / Backward Compatibility

- `DemultiplexPlan` struct stays in code but `steps` array limited to max 1 step
- `multiStepDemultiplex` request type remains but delegates to unified pipeline
- Existing `.lungfishfastq` bundles with demux derivatives are unaffected
- New `Reference Sequences/` folder created on first use (not retroactively)

---

## 9. Verification Criteria

### Phase 1
- [ ] `swift build` succeeds
- [ ] `swift test` passes
- [ ] Orient map TSV round-trips correctly
- [ ] Reference folder import creates valid .lungfishref bundle

### Phase 2
- [ ] vsearch orient produces correct oriented FASTQ
- [ ] Unoriented reads captured when option enabled
- [ ] Orient derivative bundle has correct manifest
- [ ] Secondary demux fan-out produces correct nested bundles
- [ ] Materialization via seqkit produces correct RC'd reads

### Phase 3
- [ ] Unified demux panel works for single kit
- [ ] Secondary kit disclosure expands/collapses
- [ ] Orient tab reference picker works (project + external)
- [ ] External reference auto-imports to Reference Sequences/
- [ ] Scout runs full pipeline (primary + secondary)
- [ ] All existing FASTQ operations still work

---

## 10. Expert Consensus Notes

### Genomics/Sequencing Team
- ONT→PacBio processing order is always correct (outer barcodes first)
- Window extraction (20bp) for PacBio barcodes after ONT trimming remains valid
- Orient before demux is preferred for amplicon workflows

### vsearch/Bioinformatics Team
- vsearch `--orient` preserves FASTQ quality scores (reverses them for RC'd reads)
- `--tabbedout` provides per-read orientation for lightweight storage
- `--wordlength 12` is appropriate for amplicons >200bp; lower (8) for very short amplicons
- `--dbmask none --qmask none` recommended for short amplicons (<500bp)

### UX Team
- Multi-step UI eliminated in favor of primary/secondary kit pattern
- Secondary kit hidden by default (disclosure triangle) — only ~5% of users need it
- Reference selection uses standard NSOpenPanel + project dropdown
- Orient results display as derivative in sidebar tree

### Architecture Team
- Orient map TSV is the correct lightweight format (not full FASTQ copy)
- Materialization via seqkit is on-demand, no persistent storage of oriented reads
- Reference Sequences folder is project-scoped, not global
- .lungfishref bundle reused for reference storage (already has manifest.json + FASTA support)
