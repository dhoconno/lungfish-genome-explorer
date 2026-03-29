# FASTQ Operations Evaluation Sprint Plan

## Date: 2026-03-28
## Branch: metagenomics-workflows
## Predecessor: GUI fixes commit b5dec50

---

## Objective

Systematically test every FASTQ operation in the Lungfish app, evaluate the GUI for:
1. Functional correctness (operation completes as expected)
2. Aesthetic quality (Apple HIG compliance, modern macOS aesthetic)
3. Usability (biologist workflow simulation)
4. Visual issues (overdraw, clipping, balance, crowding)

## Process

### Phase 1: Operation Catalog & Test Data Preparation
- Catalog all FASTQ operations from FASTQDatasetViewController.OperationKind
- For each operation, identify required test data
- Use existing VSP2 dataset (School001-20260216_S132_L008, 16.35M reads) where possible
- Create synthetic FASTQ datasets for operations that need specific characteristics:
  - Paired-end data (for merge, repair operations)
  - Low-quality reads (for trimming operations)
  - Reads with adapters (for adapter removal)
  - Reads with primers (for primer trimming)
  - Contaminated reads (for contaminant filter)

### Phase 2: Operation-by-Operation GUI Testing
For each operation:
1. Select the operation in the operations panel
2. Screenshot the parameter configuration interface
3. Run the operation with appropriate test data
4. Monitor progress indicators
5. Inspect the results view
6. Check export capabilities
7. Log all GUI issues (functional + aesthetic)

### Phase 3: Expert Assessment
- Bioinformatics expert: validate parameter defaults, tool usage
- UX expert: evaluate information architecture, interaction flow
- HIG expert: Apple HIG compliance, visual consistency, Dark Mode

### Phase 4: Development Sprint
Following Project Lead Agent process:
- Break issues into phases by file/module
- Parallel expert implementation
- Build verification after each phase
- Regression testing

### Phase 5: Recursive Testing
- GUI agent re-tests all operations
- Reports back to project lead
- Iterate until all issues resolved

### Phase 6: Final Report
- Comprehensive report documenting all changes
- Before/after comparison
- Test coverage summary

## FASTQ Operations to Test (18 operations + 1 wizard)

### Category: REPORTS
- [ ] **qualityReport** — "Compute Quality Report" — Tool: seqkit stats — Single-end OK

### Category: SAMPLING
- [ ] **subsampleProportion** — "Subsample by Proportion" — Tool: seqkit/reformat.sh — Single-end OK
- [ ] **subsampleCount** — "Subsample by Count" — Tool: seqkit/reformat.sh — Single-end OK

### Category: TRIMMING
- [ ] **qualityTrim** — "Quality Trim" — Tool: fastp — Single-end OK
- [ ] **adapterTrim** — "Adapter Removal" — Tool: fastp (auto-detect) — Single-end OK
- [ ] **fixedTrim** — "Fixed Trim (5'/3')" — Tool: fastp — Single-end OK
- [ ] **primerRemoval** — "PCR Primer Trimming" — Tool: cutadapt/bbduk.sh — Requires primer config

### Category: FILTERING
- [ ] **lengthFilter** — "Filter by Read Length" — Tool: seqkit seq/bbduk — Single-end OK
- [ ] **contaminantFilter** — "Contaminant Filter" — Tool: bbduk.sh (PhiX built-in) — Single-end OK
- [ ] **deduplicate** — "Remove Duplicates" — Tool: clumpify.sh — Single-end OK
- [ ] **sequencePresenceFilter** — "Filter by Sequence Presence" — Tool: cutadapt — Single-end OK

### Category: CORRECTION
- [ ] **errorCorrection** — "Error Correction" — Tool: tadpole.sh — Single-end OK

### Category: PREPROCESSING
- [ ] **orient** — "Orient Reads" — Tool: bbmap.sh — **Requires reference FASTA**

### Category: DEMULTIPLEXING
- [ ] **demultiplex** — "Demultiplex" — Tool: cutadapt-based — **Requires barcode config**

### Category: REFORMATTING
- [ ] **pairedEndMerge** — "Merge Overlapping Pairs" — Tool: bbmerge.sh — **Requires interleaved PE input**
- [ ] **pairedEndRepair** — "Repair Paired Reads" — Tool: repair.sh — **Requires interleaved PE input**

### Category: SEARCH
- [ ] **searchText** — "Find by ID/Description" — Tool: seqkit grep — Single-end OK
- [ ] **searchMotif** — "Find by Sequence" — Tool: seqkit grep — Single-end OK

### Category: CLASSIFICATION
- [ ] **classifyReads** — "Classify & Profile Reads" — Opens UnifiedMetagenomicsWizard

## Test Data Requirements

| Operation | Test Data Needed | Source |
|-----------|-----------------|--------|
| Quality Trim | Low-quality reads | Existing VSP2 or synthetic |
| Adapter Removal | Reads with adapters | Synthetic |
| Merge Overlapping | Paired-end overlapping reads | Synthetic |
| Repair Paired | Corrupted paired-end FASTQ | Synthetic |
| Demultiplex | Multiplexed reads with barcodes | Synthetic |
| Most others | Any FASTQ dataset | Existing VSP2 |
