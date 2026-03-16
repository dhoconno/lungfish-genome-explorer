# Virtual Sequence System: Comprehensive Plan

## Overview

This document captures the findings from a comprehensive multi-expert code review of the
Lungfish virtual FASTQ bundle system and defines the plan for:

1. Fixing critical correctness bugs in the existing virtual FASTQ system
2. Unifying FASTQ and FASTA operations under a common virtual sequence framework
3. Extending virtual sequence manifests to support annotations (barcodes, primers, trim
   boundaries, probe sites) that can be visualized in the Viewport and Annotation Drawer
4. Ensuring full lineage propagation so descendant virtual files inherit ALL transformation
   metadata from every ancestor

---

## Part 1: Critical Bug Fixes

### Bug 1: Orientation + Trim Materialization Produces Wrong Sequences

**Severity:** CRITICAL — silent data corruption
**Flagged by:** Sequencing expert, genomics expert, code reviewer (3 independent confirmations)

**Problem:** When the pipeline is Root → Orient → Demux, the demux trim positions are
computed relative to the **oriented** (RC'd) read. But materialization extracts from
the **root** FASTQ (original orientation) and applies trims directly. For any RC'd read,
trim_5p and trim_3p are effectively swapped, producing completely wrong sequences.

**Example:**
- Read X is 3049bp in root FASTQ
- Orient step marks it as RC (reverse complement)
- Demux trims 80bp from 5' and 24bp from 3' of the oriented read
- Correct result: `RC(root_X)[80..3025]` = 2945bp correctly oriented/trimmed
- What materialization produces: `root_X[80..3025]` = wrong orientation, wrong bases

**Root cause:** `materializeDatasetFASTQ` for `.demuxedVirtual` (FASTQDerivativeService.swift
line 1778) reads from root FASTQ and applies trims without consulting the orient map from
the parent bundle's lineage.

**Fix — Option A (recommended): Transform trim positions at storage time.**
When creating a virtual demux bundle whose lineage includes an orient step:
1. Load the orient map from the parent bundle
2. For reads marked as RC: swap trim_5p ↔ trim_3p before storing
3. Store an `isOrientAdjusted: true` flag in the manifest so materialization knows
   the trims are already relative to root orientation
4. Materialization then: extract from root → apply trims → RC if orient map says "-"

This keeps materialization simple and makes stored data self-consistent.

**Files to modify:**
- `DemultiplexingPipeline.swift` — in `run()`, after parsing cutadapt info, load parent
  orient map and adjust trim positions for RC'd reads
- `FASTQDerivativeService.swift` — `materializeDatasetFASTQ` `.demuxedVirtual` case must
  also apply orientation from lineage when materializing

### Bug 2: Two Incompatible Trim Position Formats

**Severity:** CRITICAL — future data corruption risk (currently separate code paths)

**Problem:** Two TSV formats share the same `trim-positions.tsv` filename:
- DemultiplexingPipeline writes `(trim_5p, trim_3p)` with header — base counts to remove
- FASTQTrimPositionFile uses `(trimStart, trimEnd)` — absolute 0-based coordinates

If `FASTQTrimPositionFile.compose()` is ever applied to demux-generated files, it will
produce silently wrong results because it interprets the values as absolute coordinates.

**Fix:** Unify on the absolute coordinate model `(trimStart, trimEnd)`:
- More composable: `compose()` works correctly
- More expressive: supports arbitrary intervals, not just end-trimming
- DemultiplexingPipeline must convert `(trim_5p, trim_3p)` to absolute coordinates
  before writing, which requires knowing the read length
- Alternative: add a `format` header to the TSV file (`#format trim_5p_3p` vs
  `#format absolute_coords`) and have readers dispatch accordingly

### Bug 3: PE Interleaved Read ID Collisions

**Severity:** HIGH

**Problem:** For interleaved paired-end data, R1 and R2 share the same read ID. The
`trimMap` dictionary in `extractAndTrimReads` (line 1946) overwrites R1's trims with R2's.

**Fix:** Add a mate discriminator column. The TSV becomes:
```
read_id    mate    trim_start    trim_end
READ001    1       5             142
READ001    2       0             148
```
Where mate = 0 for single-end, 1 for R1, 2 for R2.

### Bug 4: parseCutadaptInfoFile 5'/3' Heuristic

**Severity:** HIGH

**Problem:** The heuristic `seqBefore.count < seqAfter.count` misclassifies adapter
direction for symmetric barcodes and reads where adapter is near the midpoint.

**Fix:** Use the adapter name from cutadapt info file column 7. For linked adapters,
cutadapt produces separate lines for each arm with distinguishable adapter names.
The code already constructs named adapters — match the info file adapter name back
to the known 5' and 3' adapter names.

---

## Part 2: High-Severity Fixes

### Fix 5: Memory — Streaming Info File Parsing

Replace `String(contentsOf:)` in `parseCutadaptInfoFile` with line-by-line streaming
via `FileHandle` + `AsyncLineSequence`. For 10M reads this avoids ~4GB single allocation.

### Fix 6: Memory — Streaming extractAndTrimReads

Replace `var outputContent = ""` accumulation with streaming `FASTQWriter` (already
exists in codebase). Write records directly to output file.

### Fix 7: Silent try? on Trim File Writes

Replace `try?` with `try` in trim-positions.tsv writes inside the task group.
Propagate errors so failed trim writes surface as bundle creation failures.

### Fix 8: Schema Versioning

Add `schemaVersion: Int` to `FASTQDerivedBundleManifest` (default 1). Add unknown-case
fallback to `FASTQDerivativePayload` and `FASTQDerivativeOperationKind` Codable conformance
so new enum cases degrade gracefully in older app versions.

### Fix 9: Tool Version Recording

Add `toolVersion: String?` to `FASTQDerivativeOperation`. Populate automatically by
parsing tool `--version` output during execution.

### Fix 10: Atomic Sidecar Writes

Write sidecars (trim-positions.tsv, orient-map.tsv, read-ids.txt) to temp files first,
then rename into place. Same `.atomic` pattern used for manifests.

### Fix 11: Random Seed for Stochastic Operations

Add `randomSeed: UInt64?` to `FASTQDerivativeOperation`. Store and replay for
reproducible subsample/shuffle operations.

---

## Part 3: Unified Virtual Sequence System (FASTQ + FASTA)

### 3.1 Design Rationale

Currently, FASTA files live in `.lungfishref` bundles with annotations stored in SQLite
databases and BigBed files. FASTQ files live in `.lungfishfastq` bundles with derivative
metadata in JSON manifests and TSV sidecars. The two systems are completely separate.

The user wants:
- Operations (trim, subset, orient, demux, filter) to work on both FASTQ and FASTA
- Virtual derivatives of both file types
- Annotations from virtual file metadata (barcode positions, trim boundaries, primer sites)
  to be viewable in the Viewport and Annotation Drawer

### 3.2 Architecture: Sequence Bundle Abstraction

Rather than merging `.lungfishref` and `.lungfishfastq` (which serve different purposes —
reference genomes vs read datasets), we extend the **derivative manifest system** to also
support FASTA derivatives and add an **annotation layer** to both bundle types.

```
Common operations for FASTQ and FASTA:
- Subset (by read/sequence ID list)
- Trim (per-record trim positions)
- Orient (per-record RC map)
- Length filter
- Search/motif filter
- Deduplication
- Contamination filter

FASTQ-only operations:
- Quality trim (requires quality scores)
- Demultiplex (barcode detection requires quality-aware alignment)
- Error correction
- PE merge/repair

FASTA-only operations:
- (None currently — all FASTQ ops that don't need quality scores work on FASTA)
```

### 3.3 Implementation Plan

**Step 1: Abstract SequenceRecord protocol**

Create a protocol that FASTQ and FASTA records both conform to:
```swift
protocol SequenceRecord {
    var identifier: String { get }
    var sequence: String { get }
    var description: String? { get }
}
// FASTQRecord adds: quality: QualityScores
// FASTARecord adds: (nothing extra)
```

**Step 2: Generalize derivative operations**

The existing `FASTQDerivativeRequest` becomes `SequenceDerivativeRequest`. Operations
that don't require quality scores accept both FASTQ and FASTA input. The service detects
input format and routes accordingly.

**Step 3: FASTA bundle format**

FASTA derivatives use the same `.lungfishfastq` bundle structure (or a new
`.lungfishseq` extension) with the same `derived.manifest.json` format. The manifest
gains an optional `sequenceFormat: "fastq" | "fasta"` field.

**Step 4: Materialization for FASTA**

Same as FASTQ materialization but without quality score handling. `extractReads` uses
seqkit (which handles both formats). Trim application skips quality line.

---

## Part 4: Virtual Sequence Annotations

### 4.1 Design Vision

Every transformation recorded in a virtual sequence manifest becomes a potential
annotation track. When viewing a read in the Viewport:

- **Barcode annotations**: colored regions showing where ONT outer barcodes and PacBio
  inner barcodes were detected, with barcode ID labels
- **Trim annotations**: shaded regions at 5'/3' ends showing trimmed bases
- **Primer annotations**: colored arrows showing primer binding sites
- **Adapter annotations**: regions showing platform adapter locations
- **Orient annotations**: indicators showing original vs reverse-complement orientation
- **Quality trim annotations**: boundaries where quality dropped below threshold

These annotations scroll in the Annotation Drawer just like gene/CDS/exon annotations
do for reference genomes.

### 4.2 Per-Read Annotation Model

Extend the manifest system with a **per-read annotation sidecar file** that stores
structured annotations for each read. This replaces the current single-purpose TSV
files (trim-positions.tsv, orient-map.tsv, read-ids.txt) with a unified format.

**File format: `read-annotations.tsv`**

```
#format    lungfish-read-annotations-v1
#columns   read_id    mate    annotation_type    start    end    strand    label    metadata
```

Column definitions:
- `read_id`: FASTQ/FASTA header ID (up to first whitespace)
- `mate`: 0=single, 1=R1, 2=R2 (solves PE collision issue)
- `annotation_type`: enum string — `barcode_5p`, `barcode_3p`, `adapter_5p`, `adapter_3p`,
  `primer_5p`, `primer_3p`, `trim_quality`, `trim_fixed`, `orient_rc`, `umi`, etc.
- `start`: 0-based inclusive position in ROOT sequence (orientation-adjusted)
- `end`: 0-based exclusive position in ROOT sequence
- `strand`: `+` or `-` (orientation of the annotation relative to root)
- `label`: human-readable label (e.g., "BC1001", "VNP adapter", "ARTIC_v4_pool1_LEFT_23")
- `metadata`: JSON-encoded key-value pairs for additional annotation-specific data
  (e.g., `{"errorRate": 0.05, "kitName": "SQK-NBD114.96"}`)

**One read can have MULTIPLE annotations** (e.g., 5' barcode + 3' barcode + 5' adapter +
3' adapter for a single ONT read). Each annotation is a separate row.

### 4.3 Full Lineage Propagation

**Critical requirement:** When a PacBio inner demux virtual bundle is created from an
ONT outer demux parent, the inner bundle MUST inherit ALL annotations from the outer
bundle for the reads it contains. This means:

```
Root FASTQ (extraction)
  → Orient derivative: stores orient-map.tsv
    → ONT Demux outer: stores barcode annotations (ONT BC positions)
      → PacBio Demux inner: stores barcode annotations (PacBio BC positions)
        AND inherits: orient annotations + ONT barcode annotations
```

**Implementation:**

The `read-annotations.tsv` file in each virtual bundle contains the COMPLETE set of
annotations for its reads — both its own annotations AND all inherited parent annotations.
This is computed at bundle creation time:

1. Load parent bundle's `read-annotations.tsv` (if exists)
2. Filter to only reads in the current bundle's read ID list
3. Add the current operation's annotations
4. Write combined `read-annotations.tsv`

This means each leaf bundle is self-contained — materialization and annotation display
don't need to walk the lineage chain.

**Size consideration:** For 10,000 reads with 4 annotations each, the TSV is ~40 lines x
~200 bytes = ~8MB uncompressed. Acceptable for on-disk storage. For very large files,
consider gzip compression (`.tsv.gz`).

### 4.4 Annotation Types from Operations

Each operation kind produces specific annotation types:

| Operation | Annotation Type | What It Shows |
|-----------|----------------|---------------|
| Demultiplex | `barcode_5p`, `barcode_3p` | Barcode detection region + barcode ID |
| Adapter trim | `adapter_5p`, `adapter_3p` | Platform adapter location |
| Quality trim | `trim_quality_5p`, `trim_quality_3p` | Quality-trimmed region |
| Fixed trim | `trim_fixed_5p`, `trim_fixed_3p` | Hard-trimmed region |
| Orient | `orient_rc` | Full-read annotation indicating RC'd orientation |
| Primer removal | `primer_5p`, `primer_3p` | Primer binding site + primer ID |
| UMI extraction | `umi` | UMI sequence location |
| Contaminant filter | `contaminant_match` | Region matching contaminant reference |

### 4.5 Viewport Integration

**Rendering annotations on FASTQ/FASTA reads:**

The existing `SequenceViewerView` renders annotations as colored blocks on genomic
coordinates. For FASTQ/FASTA reads, the "chromosome" is the read itself, and the
coordinate system is the read's base positions.

When the user opens a virtual bundle in the read preview table and selects a read:
1. The Viewport shows the read's full sequence (like a mini chromosome)
2. Annotations from `read-annotations.tsv` for that read are rendered as colored
   blocks overlaid on the sequence
3. The Annotation Drawer shows a table of all annotations for the selected read

**Implementation approach:**

Create a lightweight `ReadAnnotationProvider` that:
- Loads `read-annotations.tsv` from the bundle
- Provides `getAnnotations(readID:)` → `[SequenceAnnotation]`
- Converts each annotation row to a `SequenceAnnotation` with:
  - `chromosome` = read ID
  - `intervals` = `[AnnotationInterval(start, end)]`
  - `type` = mapped from annotation_type string to existing `AnnotationType` enum
    (extend enum with new read-level types)
  - `name` = label field
  - `qualifiers` = parsed from metadata JSON

This reuses the existing annotation rendering infrastructure entirely — the Viewport
and Drawer don't need to know that annotations came from a virtual manifest rather
than a GFF3 file.

### 4.6 Annotation Drawer Integration

The `AnnotationTableDrawerView` already supports:
- Columns: Name, Type, Chromosome, Start, End, Size, Strand
- Filtering by type (chip buttons)
- Click-to-navigate

For read-level annotations:
- "Chromosome" column shows the read ID (or abbreviated)
- Type chips include the new annotation types (barcode, adapter, primer, etc.)
- Clicking an annotation navigates the read view to center on that feature
- Color coding matches the annotation type (distinct colors for barcode, adapter,
  primer, trim, UMI)

---

## Part 5: Sample Provenance and Study Context

### 5.1 SampleProvenance Struct

Add optional sample-level metadata to manifests, supporting NHP colony tracking,
vaccine study longitudinal design, and FAIR compliance:

```swift
public struct SampleProvenance: Codable, Sendable, Equatable {
    public var subjectID: String?        // Animal/patient ID
    public var species: String?          // "Macaca mulatta"
    public var tissueType: String?       // "PBMC", "rectal biopsy"
    public var collectionDate: Date?
    public var timepointLabel: String?   // "Week 4 post-challenge"
    public var timepointDays: Int?       // Numeric for sorting
    public var studyID: String?
    public var treatmentGroup: String?
    public var iacucProtocol: String?
    public var targetLocus: String?      // For amplicon: "Mamu-E"
    public var sortPopulation: String?   // "tetramer+CD8+"
    public var libraryType: String?      // "wgs", "amplicon", "vdj_b"
    public var customFields: [String: String]?
}
```

### 5.2 Reproducibility Manifest

Add `toolVersion: String?` and `referenceAccession: String?` to operations.
Support export of complete provenance chain as RO-Crate format for NIH compliance.

---

## Part 6: Payload Checksum and Integrity

### 6.1 Manifest Integrity

Add `payloadChecksum: String?` (SHA-256 of primary sidecar file) to manifest.
Verified on load to detect corrupt sidecars.

### 6.2 Root FASTQ Fingerprint

Store SHA-256 of the first 4KB of root FASTQ at ingestion time in `IngestionMetadata`.
Verified before materialization to detect "path resolves but to wrong file" scenarios.

### 6.3 Referential Integrity Validation

Add `validateReferences(from:) -> [ReferenceError]` to manifest that eagerly checks
whether parent and root paths resolve. Called on bundle open, not just on materialization.

Add depth guard (max lineage depth = 50) to prevent infinite recursion from circular refs.

---

## Part 7: Future Metadata Extensions

### 7.1 UMI Support (Essential for Immune Sequencing)

New operation kind `umiExtract`:
- Extracts UMI from defined read position
- Stores UMI annotation in `read-annotations.tsv`
- Produces trim derivative removing UMI bases

New operation kind `umiConsensus`:
- Groups reads by UMI + clonotype
- Produces consensus FASTQ (`.full` payload)
- Sidecar: `umi-groups.tsv` mapping consensus → raw reads

### 7.2 Contamination Classification (Essential for NHP)

New operation kind `contaminantClassify`:
- Produces TWO derivative bundles: pass and reject
- Both are virtual subsets of root FASTQ
- Reject bundle preserved for regulatory audit trail
- Annotations show matched contaminant regions

### 7.3 Host/Viral Classification (Essential for Challenge Studies)

New operation kind `hostViralClassify`:
- Produces three bundles: host-only, viral-only, chimeric/ambiguous
- Per-read annotation: classification + confidence
- Chimeric reads annotated with junction coordinates

### 7.4 V(D)J Annotation (Essential for Immune Repertoire)

New annotation types in `read-annotations.tsv`:
- `vgene`, `dgene`, `jgene`: gene segment boundaries
- `cdr3_nt`, `cdr3_aa`: CDR3 region coordinates
- `isotype`: constant region classification

Follows AIRR Community `rearrangement` format standards.

---

## Implementation Priority

### Phase 1: Critical Correctness (immediate)
1. Fix orient + trim interaction (Bug 1)
2. Fix captureTrimsForChaining missing call site (Bug 2) ✅ DONE
3. Fix PE read ID collisions (Bug 3)
4. Fix parseCutadaptInfoFile heuristic (Bug 4)
5. Add schema versioning (Fix 8)

### Phase 2: Robustness (short-term)
6. Streaming info file parsing (Fix 5)
7. Streaming extractAndTrimReads (Fix 6)
8. Atomic sidecar writes (Fix 10)
9. Tool version recording (Fix 9)
10. Unify trim position formats (Bug 2 — format unification)

### Phase 3: Annotation Infrastructure (medium-term)
11. Design `read-annotations.tsv` format
12. Implement annotation generation in DemultiplexingPipeline
13. Implement full lineage annotation propagation
14. ReadAnnotationProvider: TSV → SequenceAnnotation conversion
15. Viewport integration: read-level annotation rendering
16. Annotation Drawer integration: read annotation display

### Phase 4: FASTA Unification (medium-term, parallel with Phase 3)
17. SequenceRecord protocol abstraction
18. Generalize derivative operations for FASTA
19. FASTA materialization support
20. FASTA annotation support (same infrastructure as FASTQ)

### Phase 5: Extended Metadata (longer-term)
21. SampleProvenance struct
22. UMI extraction/consensus operations
23. Contamination classification
24. Payload checksums and integrity validation
25. Reproducibility manifest / RO-Crate export

---

## Expert Review Panel

This plan was informed by findings from 7 independent expert agents:

1. **Data structure explorer** — mapped all manifest types, payload enums, derivative structures
2. **Materialization code reviewer** — traced every creation and materialization code path
3. **Code reviewer (Swift)** — found missing captureTrimsForChaining, memory issues, silent errors
4. **Architecture reviewer** — schema versioning, atomicity, referential integrity gaps
5. **Genomics/bioinformatics expert** — orient+trim bug, UMI needs, per-read annotation format
6. **Sequencing platform expert** — orient+trim bug, two trim formats, PE collisions
7. **NHP research expert** — colony tracking, contamination filtering, regulatory compliance
8. **Immunology expert** — UMI consensus, V(D)J annotations, single-cell metadata needs

All critical bugs were confirmed by at least 2 independent experts.
