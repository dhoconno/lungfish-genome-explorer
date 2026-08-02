# Stable Sidebar, Row-Supported Columns, and Partial Class II Discovery Implementation Plan

**Goal:** Preserve sidebar navigation during refreshes, add a one-row matrix command that shows only samples with positive read support, and retain scientifically useful partial class II candidate interpretations without publishing them as complete alleles.

**Architecture:** Each fix uses its existing subsystem boundary. The sidebar captures/restores a URL-based scroll anchor around full reloads. The matrix command derives supported sample IDs from the selected row and mutates the existing visibility state. Candidate canonicalization retains an optional interpretation on incomplete un-nameable records, while public sequence exports remain gated on reference readiness.

**Tech Stack:** Swift 6, AppKit, XCTest, Swift Package Manager, openpyxl workbook projection, Lungfish provenance models.

---

### Task 1: Preserve the sidebar viewport during full reloads

**Files:**
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift`
- Test: `Tests/LungfishAppTests/SidebarViewControllerSelectionTests.swift`

- [ ] Add a hosted controller test with enough nested rows to scroll. Capture the top visible URL and its offset, call `reloadFromFilesystem()`, and assert both remain stable.
- [ ] Run `swift test --filter SidebarViewControllerSelectionTests` and confirm the new test fails because the clip origin returns to the top.
- [ ] Add a private semantic scroll-anchor value and capture/restore helpers. Capture before rebuilding; restore after expansion and selection restoration. Clamp the raw-position fallback when the anchor item no longer exists.
- [ ] Re-run the focused suite and confirm the new test passes without changing explicit `selectItem` scrolling.

### Task 2: Add the row-supported sample visibility command

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeMatrixVisibilityStateTests.swift`

- [ ] Add failing menu-state tests for an exactly-one-row command titled `Show Only Columns with Calls in This Row`, absent or disabled for invalid selection shapes, and explanatory disabled state for a zero-support row.
- [ ] Add a failing viewport test whose selected row has read counts 11, 1, and 0; invoke the command and assert only the first two sample columns remain visible.
- [ ] Add `showOnlyColumnsWithSelectedRowCalls` to the context command model and menu builder. Supply its availability from an immutable snapshot of the selected row's positive-support sample count.
- [ ] Implement the command by resolving the selected stable row and calling `visibilityState.showingOnlySamples` with samples whose raw `passedUniqueReads > 0`. Preserve row visibility and use the standard visibility update/announcement path.
- [ ] Re-run both focused suites and verify Show All restores all sample columns.

### Task 3: Retain incomplete class II candidate interpretations

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Test: `Tests/LungfishIOTests/ONTMHCCandidateAllelesV2Tests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift`
- Test: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] Add a backward-compatible optional `ONTMHCProvisionalCandidateInterpretation` model and tests that round-trip it while older schema-4 documents continue to decode.
- [ ] Add an artifact-writer test in which a valid novel candidate canonicalizes as incomplete. Assert it remains un-nameable, has no public FASTA/checksum identity, and retains its provisional interpretation. Assert unavailable and ordinary classifier failures do not gain one.
- [ ] Implement the interpretation attachment only in the incomplete candidate-demotion branch. Copy the biological interpretation from the already validated classifier record; do not change candidate classifier thresholds or public export gates.
- [ ] Add projection tests proving the incomplete record carries provisional name/locus/read counts into normalized rows and Unified, while `candidate_alleles.fasta` and candidate GenBank remain reference-ready-only.
- [ ] Extend the initial workbook builder and workbook update script to include named incomplete records as `candidate-incomplete` rows with explicit incomplete status.
- [ ] Extend the native matrix projection to combine candidate-document records with interpreted incomplete un-nameable records. Reuse the stable candidate row identity and candidate tint logic, but leave full candidate detail unavailable and show a partial-amplicon/not-reference-ready tooltip.

### Task 4: Provenance and real-data validation

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCProvenanceStepTests.swift`

- [ ] Add failing assertions for the new retained-incomplete count and exact review/export rule in the candidate transformation provenance.
- [ ] Record the count, rule, schema behavior, output descriptors, and unchanged reference-ready export boundary in the existing provenance step.
- [ ] Run the full-length workflow against `CN29_DRB_4.4.lungfishfastq` and the supplied DRB reference. Verify the 234-read exact call and the two high-support incomplete novel interpretations are present, while candidate public FASTA contains no incomplete record.
- [ ] Validate the final bundle using the normal result loader and inspect the provenance for final stored paths, checksums, file sizes, exact argv/defaults, runtime, status, and wall time.

### Task 5: Regression verification and debug build

**Files:**
- Review all changed files above.

- [ ] Run the focused sidebar, matrix, candidate model, artifact writer, workbook projection, provenance, and result-loading suites.
- [ ] Run `swift test` and read the complete result.
- [ ] Run `swift build -c debug` and launch the debug app after quitting other Lungfish instances.
- [ ] Review `git diff --check`, the full diff, and repository status. Commit only this branch's spec, tests, and implementation.

