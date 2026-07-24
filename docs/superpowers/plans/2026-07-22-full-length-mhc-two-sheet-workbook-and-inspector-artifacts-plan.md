# Full-length MHC two-sheet workbook and Inspector artifacts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task by task, with test-first implementation and review between tasks.

**Goal:** Generate a compact two-sheet full-length ONT MHC workbook whose known-allele labels match the LGE viewport, preserve analyst annotations on explicit update, expose nucleotide/translation/status data for every unmatched cluster, and make both candidate GenBank artifacts visible in the Inspector.

**Architecture:** Keep scientific identities and calls unchanged. Build one normalized Swift workbook projection from the existing report rows, embedded reference metadata, candidate documents, FASTA, and generated GenBank records. Use that projection for initial XLSX generation and the explicit update action. Resolve Inspector links only through the checksummed bundle manifest and existing validated bundle-member path handling.

**Tech Stack:** Swift, AppKit/SwiftUI, LungfishIO GenBankReader, the existing custom XLSX writer, the embedded Python/openpyxl workbook revision script, XCTest.

## Global Constraints

- Limit changes to the full-length ONT MHC workflow, workbook, result viewport Inspector surfaces, and their tests.
- Preserve raw known-reference IDs as durable call IDs; project only user-facing labels through GenBank `feature.allele`, with raw-ID fallback.
- Preserve all scientific CSV, JSON, FASTA, BAM/BAI, GenBank, statistics, and provenance artifacts.
- Record all scientific inputs and resolved defaults in reproducibility provenance, including both candidate GenBank inputs and reference metadata used by the workbook projection.
- Write failing tests before each production change.
- Build and relaunch an app named `Lungfish Debug` after the completed change set.

---

## Task 1: Normalize unmatched sequence and translation data in Swift

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`

### Step 1: Add failing projection tests

Add fixtures covering one classified candidate and one un-nameable cluster. Assert that the compact projection contains each stable cluster ID exactly once and has distinct fields for nucleotide sequence, putative amino-acid translation, and translation status.

### Step 2: Add failing translation-classification tests

Cover an intact complete CDS (`full-length`), an internal stop or frame-disrupting CDS (`pseudogene`), and insufficient lifted coverage (`incomplete/unresolved`). Assert that the generated GenBank source feature records the normalized status and that CDS translation remains available where computable.

### Step 3: Run the focused tests and confirm RED

Run:

```bash
swift test --filter FullLengthONTMHCWorkbookProjectionTests
swift test --filter FullLengthONTMHCCandidateGenBankArtifactBuilderTests
```

### Step 4: Implement the normalized projection

Add a Codable row model shared by initial generation and explicit update. Join candidate/un-nameable documents to their FASTA and generated GenBank records by stable identity. Populate metadata, per-sample support, nucleotide sequence, putative translation, and normalized status. Treat missing or ambiguous CDS evidence as `incomplete/unresolved`.

### Step 5: Emit explicit translation status in generated GenBank

Derive status alongside lifted CDS construction and store it as a source qualifier. Keep the translated sequence separate and do not infer full-length status from a translation string alone when boundary coverage is incomplete.

### Step 6: Run focused tests and confirm GREEN

Re-run both focused suites and inspect the resulting GenBank text for stable identity and status qualifiers.

---

## Task 2: Generate the two-sheet initial workbook with viewport-consistent labels

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`

### Step 1: Add failing workbook-contract tests

Assert that a newly generated workbook has exactly `Unified Genotype Pivot` and `Unmatched Alleles`. Assert that the unified sheet contains the legacy analyst header block, a separator, and the unified genotype table.

### Step 2: Add failing display-name identity tests

Use known reference records where raw ID and `feature.allele` differ. Assert that `call_id` remains raw, `display_name` is the `Mafa-*` allele value, and missing allele metadata falls back to the raw ID. Include duplicate display labels backed by distinct raw IDs and assert they remain separate rows.

### Step 3: Add failing unmatched-sheet tests

Assert that candidate and un-nameable stable IDs occur once, and that `Nucleotide Sequence`, `Putative Amino Acid Translation`, and `Translation Status` are separate columns with expected values.

### Step 4: Run focused tests and confirm RED

Run the projection and pipeline test suites.

### Step 5: Implement the two-sheet builders

Replace the legacy sheet list only for new full-length MHC workbooks. Reuse the existing pivot header calculations and analyst fields above the unified genotype table. Feed the second sheet from the normalized unmatched projection. Map known display values from embedded reference records without changing raw scientific identities or merging rows.

### Step 6: Extend workbook provenance

Record candidate and un-nameable JSON, FASTA, and GenBank inputs plus the embedded reference metadata used for display projection. Bump the workbook projection schema version so stale projections fail closed.

### Step 7: Run focused tests and confirm GREEN

Verify sheet names, cell types, raw/display identity behavior, row cardinality, and provenance inputs.

---

## Task 3: Make explicit workbook update honor the same contract

**Files:**

- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

### Step 1: Add failing explicit-update tests

Start from a workbook with analyst-entered haplotype assignments and comments. Run explicit update and assert that only the two approved sheets remain, computed cells refresh, and nonblank analyst fields survive.

### Step 2: Add failing compact-projection tests

Assert that Swift validates and supplies the normalized unmatched rows to the updater, including independent nucleotide, translation, and status values. Assert malformed or identity-inconsistent projections fail before workbook replacement.

### Step 3: Run the focused suite and confirm RED

Run:

```bash
swift test --filter GenotypeWorkbookRevisionServiceTests
```

### Step 4: Implement Swift-side update preparation

Load and validate candidate/un-nameable JSON, FASTA, and GenBank bundle members through the manifest. Produce the same compact Codable rows used by initial generation and include their source paths and checksums in revision provenance.

### Step 5: Implement the openpyxl update behavior

Locate the unified table by its `call_type` header rather than assuming row 1. Preserve nonblank haplotype/comment cells keyed by row label and sample, refresh generated header/table content, write the combined unmatched sheet, and remove legacy worksheets. Do not parse GenBank independently in Python.

### Step 6: Run focused tests and confirm GREEN

Verify atomic failure behavior, two-sheet output, analyst preservation, and provenance.

---

## Task 4: Expose candidate GenBank artifacts in both Inspector surfaces

**Files:**

- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- Test: `Tests/LungfishAppTests/GenotypeSampleMetadataImportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

### Step 1: Add failing validated-resolution tests

Assert that declared candidate and un-nameable GenBank refs resolve only when they are validated bundle members, and that traversal or checksum-invalid refs cannot become Inspector links.

### Step 2: Add failing Inspector tests

Assert that both surfaces display `Candidate Alleles GenBank` and `Un-nameable Clusters GenBank` when declared, and omit them when absent.

### Step 3: Run focused tests and confirm RED

Run the bundle, App Inspector, and genotype viewport suites filtered to the new cases.

### Step 4: Implement one validated resolver and wire both surfaces

Expose a narrow bundle API returning optional validated URLs for the two manifest refs. Use it from both Inspector lists with identical labels. Do not add filesystem fallbacks.

### Step 5: Run focused tests and confirm GREEN

Verify optional behavior and bundle-bound path safety.

---

## Task 5: Integration verification, review, and debug build

### Step 1: Run regression suites

Run the full focused suites for candidate GenBank generation, workbook projection, pipeline, explicit revision, bundle validation, SwiftUI Inspector, viewport, and debug launch configuration. Run `git diff --check`.

### Step 2: Inspect a real or freshly generated analysis bundle

Use the four approved exemplar FASTQ bundles and Mafa reference if a fresh run is needed. Verify:

- exactly two workbook tabs;
- viewport and Excel share `Mafa-*` display names while raw call IDs remain recoverable;
- every candidate and un-nameable stable ID occurs once;
- nucleotide, translation, and status columns are populated independently;
- both GenBank artifact declarations are present and checksummed;
- provenance points to final bundle payloads.

### Step 3: Request independent code review

Have one reviewer check scientific identity/provenance and another check workbook/Inspector behavior. Address any findings and rerun affected tests.

### Step 4: Build and relaunch the debug application

Quit prior Lungfish instances, run the repository debug build script, verify the product and menu name are `Lungfish Debug`, launch the new build with the test result bundle, and smoke-test row selection, detail rendering, workbook links, and bounded memory use.

### Step 5: Commit the verified implementation

Commit only the scoped implementation, tests, and documentation. Report test/build evidence and the exact debug app path.
